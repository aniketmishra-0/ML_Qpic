#!/usr/bin/env bash
#
# build_desktop_flutter.sh — End-to-end build driver for the Qpic **Flutter**
# desktop app on macOS/Linux (Req 21.4, 22.1).
#
# This replaces the legacy pywebview/PySide6 build scripts
# (`build_desktop.sh`, `build_desktop.bat`, `build_desktop_qt.sh`): instead of
# packaging a Python window app, it builds the headless PyInstaller **sidecar**
# and the native **Flutter** desktop app, then embeds the sidecar inside the
# Flutter bundle and packages an installer.
#
# Pipeline (design "Build Scripts & Dev Workflow", Req 22):
#   1. pip install -r requirements.txt -r requirements-desktop.txt   (sidecar deps)
#   2. python scripts/vendor_tesseract.py --langs eng,hin,osd        (offline OCR)
#   3. pyinstaller packaging/sidecar.spec --noconfirm                (sidecar onedir)
#   4. flutter build macos                                          ┐ delegated to
#   5. embed the sidecar + package the .dmg                         │ packaging/macos/
#   6. optional codesign + notarize (when cert env vars are set)    ┘ package_macos.sh
#
# Steps 4-6 are delegated to packaging/macos/package_macos.sh (Task 21.1), which
# runs `flutter build macos --release`, copies dist/qpic-sidecar/ into
# Qpic.app/Contents/Resources/sidecar/, builds the .dmg, and codesigns/notarizes
# only when MAC_CERT_IDENTITY / AC_NOTARY_PROFILE are present. With no cert env
# vars the build still completes with unsigned artifacts.
#
# Linux note: the repo ships desktop installers for macOS and Windows only
# (Req 21.1, 21.2). On Linux this driver builds the sidecar onedir (useful for
# dev / embedding) and stops before the macOS-only packaging step.
#
# Environment variables (passed through to package_macos.sh)
# ----------------------------------------------------------
#   PYTHON             Python interpreter to use.   Default: python3
#   MAC_CERT_IDENTITY  "Developer ID Application: …" — enables codesign.
#   AC_NOTARY_PROFILE  notarytool keychain profile  — enables notarization.
#   DMG_NAME / OUTPUT_DIR / APP_NAME — see package_macos.sh.
#
# Usage
# -----
#   ./build_desktop_flutter.sh                       # full build
#   ./build_desktop_flutter.sh --langs eng,hin       # custom Tesseract langs
#   ./build_desktop_flutter.sh --skip-deps           # reuse installed deps
#   ./build_desktop_flutter.sh --skip-sidecar        # reuse dist/qpic-sidecar
#   ./build_desktop_flutter.sh --skip-flutter-build  # reuse existing flutter build
#   MAC_CERT_IDENTITY="Developer ID Application: Acme (AB12CD34EF)" \
#     AC_NOTARY_PROFILE=qpic-notary ./build_desktop_flutter.sh   # signed + notarized
#
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

PY="${PYTHON:-python3}"
LANGS="eng,hin,osd"

SKIP_DEPS=0
SKIP_VENDOR=0
SKIP_SIDECAR=0
SKIP_FLUTTER_BUILD=0

log()  { printf '\033[1;34m[build-flutter]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build-flutter] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build-flutter] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Parse args -------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --langs)            LANGS="${2:?--langs needs a value}"; shift 2 ;;
    --langs=*)          LANGS="${1#*=}"; shift ;;
    --skip-deps)        SKIP_DEPS=1; shift ;;
    --skip-vendor)      SKIP_VENDOR=1; shift ;;
    --skip-sidecar)     SKIP_SIDECAR=1; shift ;;
    --skip-flutter-build) SKIP_FLUTTER_BUILD=1; shift ;;
    -h|--help)
      sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

command -v "${PY}" >/dev/null 2>&1 || die "Python interpreter not found: ${PY} (set PYTHON=...)."

# --- 1. Install sidecar build dependencies ----------------------------------
if [ "${SKIP_DEPS}" = "1" ]; then
  log "Skipping dependency install (--skip-deps)."
else
  log "Installing build dependencies (requirements.txt + requirements-desktop.txt)"
  "${PY}" -m pip install -r requirements.txt -r requirements-desktop.txt
fi

# --- 2. Vendor a self-contained Tesseract for offline OCR -------------------
if [ "${SKIP_VENDOR}" = "1" ]; then
  log "Skipping Tesseract vendoring (--skip-vendor)."
else
  log "Vendoring Tesseract (langs: ${LANGS})"
  if ! "${PY}" scripts/vendor_tesseract.py --langs "${LANGS}"; then
    warn "Could not vendor Tesseract. The app will still build, but OCR for"
    warn "scanned PDFs will need a system Tesseract install."
    warn "Install it first:  brew install tesseract tesseract-lang"
  fi
fi

# --- 3. Build the headless PyInstaller sidecar (onedir) ---------------------
if [ "${SKIP_SIDECAR}" = "1" ]; then
  log "Skipping sidecar build (--skip-sidecar); reusing dist/qpic-sidecar."
  [ -d "${REPO_ROOT}/dist/qpic-sidecar" ] || die "dist/qpic-sidecar not found; cannot --skip-sidecar."
else
  log "Building sidecar: pyinstaller packaging/sidecar.spec --noconfirm"
  "${PY}" -m PyInstaller packaging/sidecar.spec --noconfirm
  [ -d "${REPO_ROOT}/dist/qpic-sidecar" ] || die "Sidecar onedir not produced at dist/qpic-sidecar."
fi

# --- 4-6. Flutter build + embed sidecar + package + sign/notarize -----------
OS="$(uname -s)"
case "${OS}" in
  Darwin)
    PACKAGE_SCRIPT="${REPO_ROOT}/packaging/macos/package_macos.sh"
    [ -f "${PACKAGE_SCRIPT}" ] || die "Missing macOS packaging script: ${PACKAGE_SCRIPT}."
    log "Delegating Flutter build + embed + .dmg packaging to package_macos.sh"
    # package_macos.sh runs `flutter build macos --release`, embeds the sidecar
    # into Qpic.app/Contents/Resources/sidecar/, builds the .dmg, and
    # codesigns/notarizes only when MAC_CERT_IDENTITY/AC_NOTARY_PROFILE are set
    # (those env vars are inherited by the child process automatically).
    if [ "${SKIP_FLUTTER_BUILD}" = "1" ]; then
      SKIP_FLUTTER_BUILD=1 bash "${PACKAGE_SCRIPT}"
    else
      bash "${PACKAGE_SCRIPT}"
    fi
    log "macOS build complete. Installer is in dist/ (see package_macos.sh output above)."
    ;;
  Linux)
    warn "Linux: desktop installers target macOS and Windows only (Req 21.1, 21.2)."
    warn "The sidecar onedir was built at dist/qpic-sidecar (usable for dev/embedding),"
    warn "but no Linux Flutter installer is produced by this spec."
    warn "For Windows packaging use build_desktop_flutter.ps1 on a Windows host."
    ;;
  *)
    die "Unsupported OS for this driver: ${OS}. Use build_desktop_flutter.ps1 on Windows."
    ;;
esac

log "Done."
