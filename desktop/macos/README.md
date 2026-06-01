# macOS runner (stub)

This directory is a placeholder. The Flutter CLI was not available in the
environment where this project was scaffolded, so the native macOS runner
(Xcode project, `Runner/`, `RunnerTests/`, `Podfile`, build configs) has **not**
been generated yet.

## Regenerate the real runner

On a machine with Flutter installed and macOS desktop enabled:

```bash
cd desktop
flutter config --enable-macos-desktop
flutter create --platforms=macos .
flutter pub get
```

`flutter create .` is non-destructive to `lib/`, `pubspec.yaml`, and
`analysis_options.yaml` — it only fills in the missing native runner files.

## Notes for later packaging tasks (21.1)

- Entitlements live at `packaging/macos/entitlements.plist` (loopback network +
  child-process spawn). A starter copy is provided at
  `desktop/macos/Runner/Qpic.entitlements` for reference.
- After `flutter build macos`, the build driver copies the PyInstaller sidecar
  onedir into `Qpic.app/Contents/Resources/sidecar/` so `lib/core/paths.dart`
  can resolve `Contents/Resources/sidecar/qpic-sidecar` at runtime.
