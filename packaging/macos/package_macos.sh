#!/usr/bin/env bash
#
# package_macos.sh — Build, embed-sidecar, .dmg-package, and (optionally)
# codesign + notarize the Qpic macOS desktop app.  (Task 21.1; Req 21.1, 21.3,
# 21.4, 21.6, 21.7.)
#
# Pipeline
# --------
#   1. `flutter build macos --release`            -> build/.../<App>.app
#   2. Embed the PyInstaller sidecar onedir into  -> <App>/Contents/Resources/sidecar/
#      so lib/core/paths.dart resolves
#      `Contents/Resources/sidecar/qpic-sidecar`.
#   3. Codesign the embedded sidecar + the .app   (only when MAC_CERT_IDENTITY set)
#      with the Hardened Runtime + entitlements.plist.
#   4. Package the .app into Qpic-macOS.dmg via `hdiutil` (or `create-dmg` when
#      installed).
#   5. Notarize + staple the .dmg                 (only when AC_NOTARY_PROFILE set).
#
# Signing/notarization are HOOKS: with no cert env vars the script still
# produces a working unsigned .app + .dmg (current behavior). It never fails
# just because a certificate or notary profile is missing.
#
# Environment variables
# ---------------------
#   MAC_CERT_IDENTITY  "Developer ID Application: Name (TEAMID)" — when present,
#                      codesign the sidecar + app. Absent -> unsigned build.
#   AC_NOTARY_PROFILE  notarytool `--keychain-profile` name — when present (and
#                      the build is signed), submit + staple the .dmg.
#   SIDECAR_DIR        PyInstaller onedir to embed. Default: <repo>/dist/qpic-sidecar
#   OUTPUT_DIR         Where to write the .dmg.    Default: <repo>/dist
#   APP_NAME           Override the built .app name to locate (auto-detected by
#                      default).
#   APP_PATH           Full path to a prebuilt .app to package directly,
#                      bypassing PRODUCTS_DIR auto-detection (re-packaging).
#   DMG_NAME           Base name for the .dmg.     Default: Qpic-macOS
#   SKIP_FLUTTER_BUILD When set to 1, reuse an existing build instead of running
#                      `flutter build macos` (useful for re-packaging).
#
# Usage
# -----
#   packaging/macos/package_macos.sh
#   MAC_CERT_IDENTITY="Developer ID Application: Acme (AB12CD34EF)" \
#     AC_NOTARY_PROFILE=qpic-notary packaging/macos/package_macos.sh
#
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DESKTOP_DIR="${REPO_ROOT}/desktop"
ENTITLEMENTS="${SCRIPT_DIR}/entitlements.plist"

SIDECAR_DIR="${SIDECAR_DIR:-${REPO_ROOT}/dist/qpic-sidecar}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/dist}"
DMG_NAME="${DMG_NAME:-Qpic-macOS}"
SIDECAR_EXE_NAME="qpic-sidecar"   # must match packaging/sidecar.spec + paths.dart

log()  { printf '\033[1;34m[package-macos]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[package-macos] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[package-macos] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS packaging must run on macOS (uname=$(uname -s))."

# --- 1. flutter build macos -------------------------------------------------
if [ "${SKIP_FLUTTER_BUILD:-0}" = "1" ]; then
  log "SKIP_FLUTTER_BUILD=1 — reusing existing Flutter build."
else
  command -v flutter >/dev/null 2>&1 || die "flutter not found on PATH."
  log "Running: flutter build macos --release"
  ( cd "${DESKTOP_DIR}" && flutter build macos --release )
fi

# --- Locate the built .app --------------------------------------------------
if [ -n "${APP_PATH:-}" ]; then
  # Caller supplied a prebuilt bundle directly (re-packaging / testing).
  [ -d "${APP_PATH}" ] || die "APP_PATH does not exist: ${APP_PATH}."
else
  PRODUCTS_DIR="${DESKTOP_DIR}/build/macos/Build/Products/Release"
  [ -d "${PRODUCTS_DIR}" ] || die "Release products dir not found: ${PRODUCTS_DIR} (build the app first)."

  if [ -n "${APP_NAME:-}" ]; then
    APP_PATH="${PRODUCTS_DIR}/${APP_NAME}"
  else
    # Auto-detect the single .app bundle Flutter produced.
    APP_PATH="$(/usr/bin/find "${PRODUCTS_DIR}" -maxdepth 1 -name '*.app' -print | head -n 1)"
  fi
fi
[ -n "${APP_PATH}" ] && [ -d "${APP_PATH}" ] || die "No .app bundle found under ${PRODUCTS_DIR:-${APP_PATH}}."
APP_BASENAME="$(basename "${APP_PATH}")"
log "App bundle: ${APP_PATH}"

# --- 2. Embed the sidecar onedir -------------------------------------------
[ -d "${SIDECAR_DIR}" ] || die "Sidecar onedir not found: ${SIDECAR_DIR} (build it with: pyinstaller packaging/sidecar.spec --noconfirm)."
[ -f "${SIDECAR_DIR}/${SIDECAR_EXE_NAME}" ] || die "Sidecar executable missing: ${SIDECAR_DIR}/${SIDECAR_EXE_NAME}."

RESOURCES_DIR="${APP_PATH}/Contents/Resources"
DEST_SIDECAR_DIR="${RESOURCES_DIR}/sidecar"
log "Embedding sidecar -> ${DEST_SIDECAR_DIR}"
/bin/rm -rf "${DEST_SIDECAR_DIR}"
/bin/mkdir -p "${DEST_SIDECAR_DIR}"
# Copy the *contents* of the onedir so the exe lands at sidecar/qpic-sidecar,
# exactly where resolveSidecarExecutablePath() looks. ditto preserves perms,
# symlinks, and extended attributes of the native dylibs.
/usr/bin/ditto "${SIDECAR_DIR}/" "${DEST_SIDECAR_DIR}/"
[ -f "${DEST_SIDECAR_DIR}/${SIDECAR_EXE_NAME}" ] || die "Sidecar exe not present after copy: ${DEST_SIDECAR_DIR}/${SIDECAR_EXE_NAME}."
/bin/chmod +x "${DEST_SIDECAR_DIR}/${SIDECAR_EXE_NAME}"
log "Embedded sidecar verified at Contents/Resources/sidecar/${SIDECAR_EXE_NAME}."

# --- 3. Codesign (hook: only when MAC_CERT_IDENTITY is set) ------------------
if [ -n "${MAC_CERT_IDENTITY:-}" ]; then
  command -v codesign >/dev/null 2>&1 || die "codesign not found but MAC_CERT_IDENTITY is set."
  [ -f "${ENTITLEMENTS}" ] || die "Entitlements file not found: ${ENTITLEMENTS}."
  log "Codesigning with identity: ${MAC_CERT_IDENTITY}"

  # Sign inside-out: nested Mach-O (dylibs/.so + the sidecar exe) first, then
  # the app bundle. Hardened Runtime (--options runtime) is required for
  # notarization; --timestamp embeds a secure timestamp.
  while IFS= read -r macho; do
    codesign --force --timestamp --options runtime \
      --entitlements "${ENTITLEMENTS}" \
      --sign "${MAC_CERT_IDENTITY}" "${macho}"
  done < <(/usr/bin/find "${DEST_SIDECAR_DIR}" -type f \( -name '*.dylib' -o -name '*.so' \))

  codesign --force --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${MAC_CERT_IDENTITY}" "${DEST_SIDECAR_DIR}/${SIDECAR_EXE_NAME}"

  # Sign the whole app last (--deep is a backstop for any nested code missed
  # above; the app's own binary gets the same hardened-runtime entitlements).
  codesign --force --deep --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${MAC_CERT_IDENTITY}" "${APP_PATH}"

  log "Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  log "Code signature verified."
else
  warn "MAC_CERT_IDENTITY not set — producing an UNSIGNED build (no codesign)."
fi

# --- 4. Package the .dmg ----------------------------------------------------
/bin/mkdir -p "${OUTPUT_DIR}"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}.dmg"
/bin/rm -f "${DMG_PATH}"

if command -v create-dmg >/dev/null 2>&1; then
  log "Packaging .dmg via create-dmg -> ${DMG_PATH}"
  create-dmg \
    --volname "Qpic" \
    --app-drop-link 480 170 \
    --icon "${APP_BASENAME}" 160 170 \
    --window-size 640 360 \
    --eula "${REPO_ROOT}/LICENSE" \
    "${DMG_PATH}" "${APP_PATH}" \
    || die "create-dmg failed."
else
  log "create-dmg not installed; packaging .dmg via hdiutil -> ${DMG_PATH}"
  STAGE_DIR="$(/usr/bin/mktemp -d)"
  trap '/bin/rm -rf "${STAGE_DIR}"' EXIT
  /usr/bin/ditto "${APP_PATH}" "${STAGE_DIR}/${APP_BASENAME}"
  # Convenience drag-to-install target.
  /bin/ln -s /Applications "${STAGE_DIR}/Applications"
  hdiutil create \
    -volname "Qpic" \
    -srcfolder "${STAGE_DIR}" \
    -fs HFS+ \
    -format UDZO \
    -ov "${DMG_PATH}" \
    || die "hdiutil create failed."
fi
[ -f "${DMG_PATH}" ] || die "DMG not produced: ${DMG_PATH}."
log "Built .dmg: ${DMG_PATH}"

# Sign the .dmg itself when we have an identity (notarytool prefers a signed dmg).
if [ -n "${MAC_CERT_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "${MAC_CERT_IDENTITY}" "${DMG_PATH}"
  log "Signed .dmg."
fi

# --- 5. Notarize + staple (hook: only when AC_NOTARY_PROFILE is set) ---------
if [ -n "${AC_NOTARY_PROFILE:-}" ]; then
  if [ -z "${MAC_CERT_IDENTITY:-}" ]; then
    warn "AC_NOTARY_PROFILE is set but MAC_CERT_IDENTITY is not — notarization requires a signed build. Skipping notarization."
  else
    command -v xcrun >/dev/null 2>&1 || die "xcrun not found but AC_NOTARY_PROFILE is set."
    log "Submitting ${DMG_PATH} to notarytool (profile: ${AC_NOTARY_PROFILE})..."
    xcrun notarytool submit "${DMG_PATH}" \
      --keychain-profile "${AC_NOTARY_PROFILE}" \
      --wait \
      || die "notarytool submission failed."
    log "Stapling notarization ticket..."
    xcrun stapler staple "${DMG_PATH}" || die "stapler failed."
    log "Notarized + stapled."
  fi
else
  warn "AC_NOTARY_PROFILE not set — skipping notarization."
fi

log "Done. Output: ${DMG_PATH}"
