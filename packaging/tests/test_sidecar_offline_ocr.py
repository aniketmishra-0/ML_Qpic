"""Integration + property tests for the headless sidecar (task 1.3).

Covers three things the design/spec require for the sidecar bootstrap and the
offline-OCR guarantee, all without adding/modifying anything under ``app/``:

1. **Headless start + health (Req 2.6, 2.7).** Spawn the real sidecar entry
   point with ``QPIC_PORT``/``QPIC_TEMP_DIR``, poll ``GET /api/health`` until it
   reports ``{"status":"ok"}``, and assert the process produced no
   missing-module / import errors on the way up.

2. **Bundled-Tesseract lookup order + ``TESSDATA_PREFIX`` (Req 20.2, 20.3).**
   Drive ``tesseract_locator.configure_tesseract`` against a fake bundle and
   assert the documented priority (``TESSERACT_CMD`` → bundled → system → PATH)
   is honored and that the bundled ``tessdata`` is wired into
   ``TESSDATA_PREFIX``.

3. **Property 11: Offline OCR (Req 1.8, 20.4).** With no AI key configured
   (Online off), running OCR makes zero non-loopback network calls. A socket
   guard records any attempt to connect to a non-loopback address while OCR runs
   over a range of Hypothesis-generated inputs.

How the sidecar is launched
---------------------------
The design's dev fallback is ``python -m packaging.sidecar``. In this
environment the PyPI ``packaging`` distribution is installed and shadows the
repo's ``packaging/`` directory (which is a namespace dir with no
``__init__.py``), so ``-m packaging.sidecar`` resolves to the wrong package.
We therefore launch the sidecar by file path with the same interpreter, which
is behaviorally identical: ``sidecar.py`` inserts the resource dir onto
``sys.path`` itself and imports the unchanged ``app.main:app``.
"""

from __future__ import annotations

import io
import os
import socket
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, List
from unittest import mock

import fitz  # PyMuPDF — used only to build a text-free image PDF for OCR input.
import httpx
import pytest
from hypothesis import HealthCheck, given, settings as hyp_settings, strategies as st
from PIL import Image, ImageDraw

from app.config import Settings
from app.services.detector import tesseract_locator
from app.services.pdf_tools.edit_service import ocr_pdf

REPO_ROOT = Path(__file__).resolve().parents[2]
SIDECAR_PY = REPO_ROOT / "packaging" / "sidecar.py"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _free_port() -> int:
    """Grab a free localhost port the same way the SidecarManager will."""

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _image_pdf_from_text(text: str, dpi_hint: int = 150) -> bytes:
    """Build a single-page PDF whose page is an *image* (no text layer).

    An image-only page forces ``ocr_pdf`` down the real OCR path (the engine
    skips pages that already carry selectable text), so the property exercises
    OCR rather than a passthrough.
    """

    width, height = 480, 140
    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    draw.text((8, 60), text or " ", fill="black")
    buf = io.BytesIO()
    img.save(buf, format="PNG")

    doc = fitz.open()
    try:
        page = doc.new_page(width=width, height=height)
        page.insert_image(fitz.Rect(0, 0, width, height), stream=buf.getvalue())
        return doc.tobytes()
    finally:
        doc.close()


def _is_loopback(host: object) -> bool:
    """True for loopback / local hosts that are allowed during offline OCR."""

    if not isinstance(host, str):
        # Non-string addresses (e.g. AF_UNIX paths) are local IPC, not network.
        return True
    h = host.strip().lower()
    if h in {"", "localhost", "127.0.0.1", "::1", "0.0.0.0", "::"}:
        return True
    return h.startswith("127.")


class _NonLoopbackGuard:
    """Records any attempt to open a non-loopback network connection."""

    def __init__(self) -> None:
        self.violations: List[str] = []

    def _host_of(self, address: object) -> object:
        if isinstance(address, (tuple, list)) and address:
            return address[0]
        return address

    def note(self, address: object) -> None:
        host = self._host_of(address)
        if not _is_loopback(host):
            self.violations.append(str(host))


@contextmanager
def _block_non_loopback() -> Iterator[_NonLoopbackGuard]:
    """Patch the socket entry points so any non-loopback call is recorded.

    Loopback traffic is left working; only outbound (non-loopback) connections
    and DNS lookups are flagged, which is exactly the Req 1.8 / 20.4 invariant.
    """

    guard = _NonLoopbackGuard()

    real_connect = socket.socket.connect
    real_connect_ex = socket.socket.connect_ex
    real_create_connection = socket.create_connection
    real_getaddrinfo = socket.getaddrinfo

    def connect(self, address):  # type: ignore[no-untyped-def]
        if self.family in (socket.AF_INET, socket.AF_INET6):
            guard.note(address)
        return real_connect(self, address)

    def connect_ex(self, address):  # type: ignore[no-untyped-def]
        if self.family in (socket.AF_INET, socket.AF_INET6):
            guard.note(address)
        return real_connect_ex(self, address)

    def create_connection(address, *args, **kwargs):  # type: ignore[no-untyped-def]
        guard.note(address)
        return real_create_connection(address, *args, **kwargs)

    def getaddrinfo(host, *args, **kwargs):  # type: ignore[no-untyped-def]
        if not _is_loopback(host):
            guard.violations.append(str(host))
        return real_getaddrinfo(host, *args, **kwargs)

    with mock.patch.object(socket.socket, "connect", connect), \
            mock.patch.object(socket.socket, "connect_ex", connect_ex), \
            mock.patch.object(socket, "create_connection", create_connection), \
            mock.patch.object(socket, "getaddrinfo", getaddrinfo):
        yield guard


@pytest.fixture(autouse=True)
def _restore_tesseract_config() -> Iterator[None]:
    """Keep tesseract-locator global state from leaking between tests.

    ``configure_tesseract`` mutates module globals *and* ``os.environ``
    (``TESSDATA_PREFIX``) directly — those writes aren't tracked by monkeypatch,
    so we snapshot and restore them here. Without this, the bundled-lookup test
    would leave ``TESSDATA_PREFIX`` pointing at its fake (empty) tessdata and
    break OCR in a later test.
    """

    import pytesseract

    saved_cmd = pytesseract.pytesseract.tesseract_cmd
    saved_configured = tesseract_locator._configured
    saved_env = {k: os.environ.get(k) for k in ("TESSDATA_PREFIX", "TESSERACT_CMD")}
    try:
        yield
    finally:
        pytesseract.pytesseract.tesseract_cmd = saved_cmd
        tesseract_locator._configured = saved_configured
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


# ---------------------------------------------------------------------------
# 1. Headless start + health (Req 2.6, 2.7)
# ---------------------------------------------------------------------------

def test_sidecar_starts_headless_and_reports_ready() -> None:
    """Spawn the sidecar, poll health to ready, and assert a clean import."""

    port = _free_port()
    with tempfile.TemporaryDirectory() as temp_dir:
        env = dict(os.environ)
        env["QPIC_PORT"] = str(port)
        env["QPIC_TEMP_DIR"] = temp_dir
        # No AI key / Online off — the offline configuration.
        env["ANTHROPIC_API_KEY"] = ""
        env["OPENROUTER_API_KEY"] = ""

        proc = subprocess.Popen(
            [sys.executable, str(SIDECAR_PY)],
            cwd=str(REPO_ROOT),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        ready = False
        health: dict = {}
        deadline = time.time() + 30.0  # design's 30s startup budget (Req 3.3).
        try:
            base_url = f"http://127.0.0.1:{port}"
            while time.time() < deadline:
                if proc.poll() is not None:
                    break  # process died early; fall through to diagnostics.
                try:
                    resp = httpx.get(f"{base_url}/api/health", timeout=1.0)
                    if resp.status_code == 200 and resp.json().get("status") == "ok":
                        health = resp.json()
                        ready = True
                        break
                except httpx.HTTPError:
                    pass
                time.sleep(0.5)  # poll every 500ms (Req 3.3).
        finally:
            proc.terminate()
            try:
                _, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                _, stderr = proc.communicate()

        assert ready, f"sidecar never became healthy. stderr:\n{stderr}"
        # No missing-module / import failures while bringing the engine up.
        for marker in ("ModuleNotFoundError", "No module named", "ImportError"):
            assert marker not in (stderr or ""), f"sidecar import error:\n{stderr}"
        # Offline posture: tesseract present, AI tier off (no key).
        assert health.get("tesseract_available") is True
        assert health.get("ai_available") is False


# ---------------------------------------------------------------------------
# 2. Bundled-Tesseract lookup order + TESSDATA_PREFIX (Req 20.2, 20.3)
# ---------------------------------------------------------------------------

def _make_fake_tesseract(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    name = "tesseract.exe" if os.name == "nt" else "tesseract"
    binary = directory / name
    binary.write_text("#!/bin/sh\nexit 0\n")
    if os.name != "nt":
        binary.chmod(0o755)
    return binary


def test_lookup_prefers_bundled_and_sets_tessdata_prefix(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bundled copy beats system/PATH and wires up the bundled tessdata."""

    bundle = tmp_path / "bundle"
    bundled_bin = _make_fake_tesseract(bundle / "tesseract")
    bundled_tessdata = bundle / "tesseract" / "tessdata"
    bundled_tessdata.mkdir()

    monkeypatch.setattr(tesseract_locator, "_bundle_dirs", lambda: [bundle])
    monkeypatch.delenv("TESSERACT_CMD", raising=False)
    monkeypatch.delenv("TESSDATA_PREFIX", raising=False)

    chosen = tesseract_locator.configure_tesseract(force=True)

    assert Path(chosen) == bundled_bin
    assert os.environ.get("TESSDATA_PREFIX") == str(bundled_tessdata)


def test_explicit_tesseract_cmd_overrides_bundled(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``TESSERACT_CMD`` wins over the bundled copy (top of the lookup order)."""

    bundle = tmp_path / "bundle"
    _make_fake_tesseract(bundle / "tesseract")

    override = tmp_path / "override"
    override_bin = _make_fake_tesseract(override)

    monkeypatch.setattr(tesseract_locator, "_bundle_dirs", lambda: [bundle])
    monkeypatch.setenv("TESSERACT_CMD", str(override_bin))
    monkeypatch.delenv("TESSDATA_PREFIX", raising=False)

    chosen = tesseract_locator.configure_tesseract(force=True)

    assert Path(chosen) == override_bin


# ---------------------------------------------------------------------------
# 3. Property 11: Offline OCR — no non-loopback calls (Req 1.8, 20.4)
# ---------------------------------------------------------------------------

@hyp_settings(
    max_examples=15,
    deadline=None,  # Tesseract shells out to a subprocess; timing varies.
    suppress_health_check=[HealthCheck.too_slow],
)
@given(
    text=st.text(
        alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd"), whitelist_characters=" "),
        min_size=0,
        max_size=32,
    ),
    dpi=st.integers(min_value=120, max_value=200),
)
def test_offline_ocr_makes_no_non_loopback_calls(text: str, dpi: int) -> None:
    """**Property 11: Offline OCR**

    With no AI key configured (Online off), OCR runs entirely on the local
    Tesseract and makes no non-loopback network call.

    **Validates: Requirements 1.8, 20.4**
    """

    # Precondition: the engine is in its offline posture (no usable AI key).
    offline_settings = Settings(ANTHROPIC_API_KEY="", OPENROUTER_API_KEY="")
    assert offline_settings.ai_is_configured() is False

    pdf_bytes = _image_pdf_from_text(text, dpi_hint=dpi)

    with _block_non_loopback() as guard:
        result = ocr_pdf(pdf_bytes, languages="eng", dpi=dpi)

    # OCR actually executed against the image page (not a text-layer passthrough).
    assert result.pages_ocred >= 1
    # The invariant: zero outbound (non-loopback) network activity during OCR.
    assert guard.violations == [], f"non-loopback calls during OCR: {guard.violations}"
