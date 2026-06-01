# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the Qpic headless **sidecar**.

Adapted from the repo-root ``desktop.spec`` with two deliberate changes (design
"Sidecar Packaging", Req 2 / 20):

1. The entry point is ``packaging/sidecar.py`` — the headless launcher that runs
   the unchanged FastAPI engine (``app.main:app``) on a private localhost port,
   with no pywebview/PySide6 window. This keeps the bundle smaller and lets the
   Flutter app own the window.
2. The build is **onedir** (``COLLECT`` with no ``BUNDLE``) so the Flutter
   installer can embed the produced folder verbatim:
     - macOS: copied into ``Qpic.app/Contents/Resources/sidecar/``
     - Windows: copied into the runner's ``sidecar/`` subfolder
   The executable is named ``qpic-sidecar`` so ``paths.dart`` can resolve
   ``sidecar/qpic-sidecar`` (``qpic-sidecar.exe`` on Windows).

Build (from the repo root):
    pyinstaller packaging/sidecar.spec --noconfirm
    # -> dist/qpic-sidecar/qpic-sidecar[.exe]
"""

import os

from PyInstaller.utils.hooks import collect_submodules, collect_data_files

block_cipher = None

# Resolve the repo root from the spec's own location so resource paths work no
# matter which directory PyInstaller is invoked from. ``SPECPATH`` is injected
# by PyInstaller as the directory containing this spec (``<root>/packaging``);
# its parent is the repo root that holds ``static/``, ``app/`` and ``vendor/``.
ROOT = os.path.dirname(os.path.abspath(SPECPATH))


def _root(*parts):
    return os.path.join(ROOT, *parts)


# Headless launcher entry point (no pywebview/Qt). Req 2.1.
ENTRY = _root("packaging", "sidecar.py")

# Ship the web UI and the app package source alongside the binary so the engine
# and static assets resolve from the bundle's own location (Req 2.2, 2.5).
datas = [
    (_root("static"), "static"),
    (_root("app"), "app"),
]

# Bundle the self-contained Tesseract when it was vendored
# (scripts/vendor_tesseract.py). This places the binary + libs + tessdata at
# <bundle>/tesseract/, exactly where app.services.detector.tesseract_locator
# looks at runtime, so OCR works with no separate Tesseract install
# (Req 2.3, 20.1). Identical rule to desktop.spec.
if os.path.isdir(_root("vendor", "tesseract")):
    datas += [(_root("vendor", "tesseract"), "tesseract")]
    print("sidecar.spec: bundling vendored Tesseract from vendor/tesseract")
else:
    print(
        "sidecar.spec: WARNING no vendor/tesseract found — OCR will require a "
        "system Tesseract install. Run scripts/vendor_tesseract.py to bundle it."
    )

# pymupdf (imported as ``fitz``) occasionally needs its data files bundled.
datas += collect_data_files("fitz", include_py_files=False)

# Pull in dynamically-imported modules PyInstaller can't see by static analysis.
# Same set as desktop.spec so the sidecar starts with no missing-module errors
# (Req 2.2, 2.6).
hiddenimports = []
hiddenimports += collect_submodules("uvicorn")
hiddenimports += collect_submodules("fastapi")
hiddenimports += collect_submodules("anthropic")
hiddenimports += ["h11", "anyio", "click", "pydantic_settings"]

a = Analysis(
    [ENTRY],
    pathex=[ROOT],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "pytest", "matplotlib"],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,  # onedir: binaries live next to the exe via COLLECT
    name="qpic-sidecar",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,  # headless child process — no terminal window
    disable_windowed_traceback=False,
    argv_emulation=False,  # headless: no macOS file-open events to handle
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# onedir output the Flutter installer embeds. No BUNDLE/.app wrapper — the
# sidecar is an embedded child process, not a standalone macOS application.
coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="qpic-sidecar",
)
