# Qpic Desktop (Flutter)

Native macOS + Windows desktop client for the Qpic FastAPI engine. The Flutter
app contains **zero engine logic** — all processing is delegated to the engine
over its existing localhost HTTP API, and page previews are server-rendered
PNGs. The engine under `app/` is never modified.

## Status

This is the initial scaffold (spec task 3.1). It contains:

- `pubspec.yaml` with the required dependencies
- `lib/main.dart` — entry point
- `lib/app.dart` — a `MaterialApp` skeleton
- `lib/{core,models,features,widgets}/` — the feature tree (filled by later tasks)
- `analysis_options.yaml` — `flutter_lints`

> The native runners under `macos/` and `windows/` are **stubs**. The Flutter
> CLI was unavailable when this was scaffolded, so the Xcode/CMake runner
> projects were not generated. See `macos/README.md` and `windows/README.md`.

## Run from source (developer)

Requires Flutter (3.24+) with desktop enabled:

```bash
cd desktop
flutter config --enable-macos-desktop      # or --enable-windows-desktop
flutter create --platforms=macos,windows . # regenerate native runners (non-destructive to lib/)
flutter pub get
flutter run -d macos                        # or -d windows
```

In dev, the sidecar runs via the repo's Python (`python -m packaging.sidecar`)
as a fallback when no packaged sidecar is embedded (see `lib/core/paths.dart`,
added in task 3.2).
