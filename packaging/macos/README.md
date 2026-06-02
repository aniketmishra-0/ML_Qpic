# macOS packaging

Builds the Qpic macOS desktop app, embeds the PyInstaller sidecar, packages a
`.dmg`, and optionally codesigns + notarizes it (Req 21.1, 21.3, 21.4, 21.7).

## Files

| File | Purpose |
|---|---|
| `package_macos.sh` | End-to-end macOS packager: `flutter build macos` → embed sidecar → codesign (hook) → `.dmg` → notarize + staple (hook). |
| `entitlements.plist` | Hardened-Runtime entitlements applied at codesign time to the app and the embedded sidecar. Loopback-only network + child-process/embedded-interpreter grants. |

## Prerequisites

Build the sidecar onedir first (owned by the sidecar spec / build driver,
task 22.1):

```bash
pip install -r requirements.txt -r requirements-desktop.txt
python scripts/vendor_tesseract.py --langs eng,hin,osd
pyinstaller packaging/sidecar.spec --noconfirm   # -> dist/qpic-sidecar/
```

## Run

```bash
# Unsigned build (no certificates needed):
packaging/macos/package_macos.sh

# Signed + notarized build:
export MAC_CERT_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export AC_NOTARY_PROFILE="qpic-notary"   # an `xcrun notarytool store-credentials` profile
packaging/macos/package_macos.sh
```

Output: `dist/Qpic-macOS.dmg`.

## Signing / notarization hooks (Req 21.4, 21.7)

Both are **gated on environment variables** so the same script works on a
contributor's machine with no Apple Developer account:

- `MAC_CERT_IDENTITY` present → `codesign --options runtime` (Hardened Runtime)
  the embedded sidecar dylibs/exe and the `.app`, using `entitlements.plist`.
  Absent → unsigned build (current behavior).
- `AC_NOTARY_PROFILE` present (and the build is signed) → `xcrun notarytool
  submit --wait` the `.dmg`, then `xcrun stapler staple`. Absent → skip.

## Sidecar embedding (Req 21.3)

The sidecar onedir is copied to `Qpic.app/Contents/Resources/sidecar/`, so the
Flutter app's `lib/core/paths.dart` resolves
`Contents/Resources/sidecar/qpic-sidecar` relative to the running bundle.

## Sandbox note

This targets **direct distribution** (Developer ID + notarization), not the Mac
App Store, so the build uses the Hardened Runtime **without** the App Sandbox.
A sandboxed parent cannot reliably exec an embedded Python/PyInstaller
interpreter that loads its own separately built dylibs; Hardened Runtime with
`disable-library-validation` is the appropriate model here. See the design
"Packaging & Installers — macOS".
