# Windows packaging (Req 21.2, 21.3, 21.5, 21.6, 21.7)

Builds a Windows installer for the Qpic Flutter desktop app that embeds the
headless PyInstaller **sidecar** (engine) together with its **bundled
Tesseract**, so the app resolves and launches the sidecar at runtime via
`desktop/lib/core/paths.dart`
(`<install dir>\sidecar\qpic-sidecar.exe`).

## Files

| File | Purpose |
|------|---------|
| `build_windows.ps1` | End-to-end driver: `flutter build windows` → embed sidecar → sign → build installer (MSIX default, NSIS alternative) → sign installer. |
| `installer.nsi` | NSIS script that packs the runner output (incl. `sidecar\`) into a single `.exe` installer. |

MSIX configuration lives in `desktop/pubspec.yaml` under `msix_config:` and the
`msix` dev dependency.

## Prerequisites (Windows host only)

These steps **must run on Windows** — they shell out to `flutter build
windows`, `signtool`, the `msix` package, and (for NSIS) `makensis`. They
cannot run on macOS/Linux.

1. Build the sidecar onedir from the repo root:
   ```powershell
   pyinstaller packaging/sidecar.spec --noconfirm   # -> dist/qpic-sidecar/
   ```
   (Run `python scripts/vendor_tesseract.py --langs eng,hin,osd` first so the
   onedir includes `tesseract/`.)
2. Have the Flutter Windows runner generated (`flutter create --platforms=windows .`
   in `desktop/`) and Windows desktop enabled.

## Usage

```powershell
# Default: unsigned MSIX
pwsh packaging/windows/build_windows.ps1

# NSIS installer instead of MSIX
pwsh packaging/windows/build_windows.ps1 -Installer nsis

# Reuse an existing flutter build (skip the rebuild)
pwsh packaging/windows/build_windows.ps1 -SkipFlutterBuild
```

Output is written to `dist/`:
- MSIX: `dist/Qpic-Windows.msix`
- NSIS: `dist/Qpic-Windows-Setup.exe`

## Authenticode signing (Req 21.7)

Signing is **fully gated on environment variables** — absent means a clean
unsigned build.

| Variable | Meaning |
|----------|---------|
| `WIN_CERT_PATH` | Path to a `.pfx` code-signing certificate. Enables signing. |
| `WIN_CERT_PASSWORD` | Password for the `.pfx`. Required with `WIN_CERT_PATH`. |
| `WIN_SIGN_THUMBPRINT` | Alternative: sign with a cert already in the store, by SHA-1 thumbprint (instead of a `.pfx`). |
| `WIN_TIMESTAMP_URL` | RFC-3161 timestamp server (default: DigiCert). |

When configured, the driver signs the **app exe** and **sidecar exe** before
packaging, and:
- MSIX: the package itself is signed by `msix:create` via the same certificate.
- NSIS: the produced `.exe` installer is signed with `signtool` after `makensis`.

When neither `WIN_CERT_PATH`+`WIN_CERT_PASSWORD` nor `WIN_SIGN_THUMBPRINT` is
set, all signing steps are skipped and the build still succeeds with unsigned
artifacts.

## How the sidecar + Tesseract get embedded (Req 21.3)

`packaging/sidecar.spec` produces a PyInstaller **onedir** at
`dist/qpic-sidecar/` that already contains the bundled Tesseract at
`dist/qpic-sidecar/tesseract/`. The driver copies the *contents* of that folder
into `<runner>\sidecar\`, so the exe lands at `<runner>\sidecar\qpic-sidecar.exe`
and Tesseract at `<runner>\sidecar\tesseract\` — exactly where the sidecar's
`tesseract_locator` looks. The installer then ships the whole runner folder,
preserving `sidecar\` at the install root.
