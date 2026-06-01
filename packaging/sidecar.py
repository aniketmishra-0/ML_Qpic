"""Headless sidecar launcher for Qpic.

This is the entry point PyInstaller bundles for the Flutter desktop app. It runs
the **unchanged** FastAPI engine (``app.main:app``) on a private localhost port
using the same uvicorn stack ``desktop.py`` runs today via ``_run_server`` —
just without the native window. The Flutter ``SidecarManager`` owns port
selection and the writable temp dir and hands them to this process through the
``QPIC_PORT`` and ``QPIC_TEMP_DIR`` environment variables.

Nothing about the engine changes: this module only resolves bundled resources,
points the engine's temp dir at the per-user writable folder, configures the
vendored Tesseract via the existing locator, and serves the app.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _resource_dir() -> Path:
    """Directory that holds bundled resources (``static/``, ``app/``).

    Under PyInstaller the files are extracted to ``sys._MEIPASS``; when running
    from source it's this file's parent (the repo root, one level up from
    ``packaging/``). Mirrors ``desktop._resource_dir`` so ``app`` and ``static``
    resolve identically in both builds.
    """

    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        return Path(meipass)
    # From source: packaging/sidecar.py -> repo root holds app/ and static/.
    return Path(__file__).resolve().parent.parent


def main() -> int:
    # Make bundled resources importable / discoverable (Req 2.5): the engine and
    # static assets are loaded from the executable's own bundle location, not the
    # working directory or absolute env paths.
    res = _resource_dir()
    if str(res) not in sys.path:
        sys.path.insert(0, str(res))

    # Port is owned by the Flutter side (Req 3.1/3.2); the sidecar simply honors
    # it. Fail fast with a readable message rather than a bare KeyError so a
    # misconfigured launch is diagnosable (Req 2.7).
    port_raw = os.environ.get("QPIC_PORT")
    if not port_raw:
        sys.stderr.write("Qpic sidecar: QPIC_PORT is not set.\n")
        return 2
    try:
        port = int(port_raw)
    except ValueError:
        sys.stderr.write(f"Qpic sidecar: QPIC_PORT is not an integer: {port_raw!r}\n")
        return 2

    # Keep crop jobs in the per-user writable folder chosen by the Flutter side
    # (Req 3.11). ``setdefault`` so an explicit TEMP_DIR override still wins.
    temp_dir = os.environ.get("QPIC_TEMP_DIR")
    if temp_dir:
        os.environ.setdefault("TEMP_DIR", temp_dir)

    # Point pytesseract at the vendored binary using the unchanged lookup order
    # (TESSERACT_CMD -> bundled -> system -> PATH) so OCR stays offline
    # (Req 20.2/20.3).
    from app.services.detector import tesseract_locator

    tesseract_locator.configure_tesseract()

    host = "127.0.0.1"

    import uvicorn

    from app.main import app  # the unchanged FastAPI app

    # Identical to desktop._run_server: the pure-python asyncio/h11 stack (no
    # uvloop/httptools/websockets) keeps the PyInstaller bundle portable.
    config = uvicorn.Config(
        app,
        host=host,
        port=port,
        log_level="warning",
        loop="asyncio",
        http="h11",
        ws="none",
    )
    uvicorn.Server(config).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
