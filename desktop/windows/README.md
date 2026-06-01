# Windows runner (stub)

This directory is a placeholder. The Flutter CLI was not available in the
environment where this project was scaffolded, so the native Windows runner
(CMake project, `runner/`, `flutter/` ephemeral configs, `Runner.rc`) has
**not** been generated yet.

## Regenerate the real runner

On a Windows machine with Flutter installed and Windows desktop enabled:

```powershell
cd desktop
flutter config --enable-windows-desktop
flutter create --platforms=windows .
flutter pub get
```

`flutter create .` is non-destructive to `lib/`, `pubspec.yaml`, and
`analysis_options.yaml` — it only fills in the missing native runner files.

## Notes for later packaging tasks (21.2)

- After `flutter build windows`, the build driver copies the PyInstaller
  sidecar onedir into the runner's `sidecar/` subfolder so
  `lib/core/paths.dart` can resolve the sidecar exe at runtime.
- Bundled Tesseract ships alongside the sidecar (see design "Tesseract
  bundling & lookup").
