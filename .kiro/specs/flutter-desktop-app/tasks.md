# Implementation Plan: Flutter Desktop App

## Overview

This plan replaces Qpic's pywebview/PySide6 desktop shells with a native Flutter desktop app (macOS + Windows) that drives the **unchanged** FastAPI engine via a PyInstaller sidecar over localhost HTTP. Implementation follows the design's five stages — sidecar bootstrap, core scaffolding, review canvas (high-risk parity gate), Rename Batch + Tools, and packaging/CI — verifying parity at each step.

**Hard constraint observed by every task below:** no task adds, removes, or modifies any file under `app/` (routers, services, detector pipeline, `schemas.py`). The Flutter app contains zero engine logic; all processing is delegated to the engine over its existing HTTP API, and page previews are server-rendered PNGs.

Implementation languages (from the design): **Dart/Flutter** for the desktop client under `desktop/`, **Python** for the headless sidecar under `packaging/`.

## Tasks

- [x] 1. Sidecar headless launcher and PyInstaller packaging
  - [x] 1.1 Implement `packaging/sidecar.py` headless launcher
    - Reuse `desktop.py` bootstrap minus the window: insert the resource dir (`sys._MEIPASS` when frozen) onto `sys.path`; read `QPIC_PORT` and `QPIC_TEMP_DIR` from env; call `tesseract_locator.configure_tesseract()`; run `uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, loop="asyncio", http="h11", ws="none"))` with `from app.main import app`
    - Engine import is unchanged; do NOT modify any file under `app/`
    - _Requirements: 1.2, 2.1, 2.5, 3.11, 20.2, 20.3_
  - [x] 1.2 Author `packaging/sidecar.spec` (PyInstaller onedir)
    - Adapt `desktop.spec` to the headless entry point; `datas`: `("static","static")`, `("app","app")`, `collect_data_files("fitz")`, `("vendor/tesseract","tesseract")` when present; `hiddenimports`: `collect_submodules` for uvicorn/fastapi/anthropic + `h11,anyio,click,pydantic_settings`; `console=False`; `excludes=[tkinter,pytest,matplotlib]`; onedir output for embedding
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.6, 20.1_
  - [x] 1.3 Write integration test for headless sidecar start, health, and offline OCR
    - Spawn the sidecar with `QPIC_PORT`/`QPIC_TEMP_DIR`, poll `GET /api/health` to ready, assert no missing-module errors, assert bundled-Tesseract lookup order and `TESSDATA_PREFIX` are honored, and assert no non-loopback calls occur during OCR with no AI key and Online off
    - **Property 11: Offline OCR**
    - **Validates: Requirements 1.8, 2.6, 2.7, 20.4**

- [x] 2. Checkpoint - sidecar boots headless and reports ready
  - Ensure all tests pass, ask the user if questions arise.

- [x] 3. Flutter project scaffolding, platform paths, and theme
  - [x] 3.1 Create the Flutter desktop project under `desktop/`
    - `pubspec.yaml` with deps `dio`, `file_selector`, `desktop_drop`, `window_manager`, `shared_preferences`, `path`, `path_provider`; `lib/`, `macos/`, `windows/` directories; `main.dart` + `app.dart` (MaterialApp skeleton); enable macOS and Windows desktop
    - _Requirements: 21.6, 24.1_
  - [x] 3.2 Implement `lib/core/paths.dart`
    - Per-OS Writable_Data_Dir (`~/Library/Application Support/Qpic/temp` on macOS, `%LOCALAPPDATA%\Qpic\temp` on Windows); `sidecarExecutablePath()` resolving the embedded sidecar per OS, with a dev fallback to `python -m packaging.sidecar`
    - _Requirements: 3.11, 24.4_
  - [x] 3.3 Implement `lib/core/theme_controller.dart`
    - `ThemeMode` light/dark/system persisted via `shared_preferences`; default `system` on first launch and re-apply stored value on launch; `system` follows `platformBrightness` live; light/dark palettes reproduce the web CSS variables used by box outlines and note chips
    - _Requirements: 4.5, 4.6, 4.7, 4.8, 4.9_
  - [x] 3.4 Write tests for theme persistence and system-follow
    - Persist/restore selection across restart; default `system`; live OS-brightness follow
    - _Requirements: 4.6, 4.7, 4.8, 4.9_

- [x] 4. DTOs and ApiClient (exact engine contract)
  - [x] 4.1 Implement DTOs in `lib/models/` mirroring `schemas.py`
    - `crop.dart`, `analyze.dart`, `rename.dart`, `tools.dart` as transport-only data classes with exact JSON keys (`x_start_pct`, `questions_download_url`, `answer_key_count`, `preview_url`, etc.); client-only UI flags (`editing`, `manualOrder`) never serialized; no engine logic in Dart
    - _Requirements: 1.3, 1.4_
  - [x] 4.2 Write DTO (de)serialization tests against captured engine JSON fixtures
    - Round-trip parse/encode preserving field names and nullability; confirm no crop/detection/OCR/PDF artifacts are computed in Dart
    - **Property 2: No Dart engine logic**
    - **Validates: Requirements 1.4, 1.5**
  - [x] 4.3 Implement `lib/core/api_client.dart` (Dio bound to Base_URL)
    - Implement every endpoint from the design endpoint table verbatim (paths, query-parameter names, form-field names, multipart field names); typed `ApiException(statusCode, detail)` surfacing the engine `{"detail": ...}` body verbatim
    - _Requirements: 1.1, 1.3, 5.4, 6.1, 7.1, 9.1, 11.4, 12.2, 12.3, 12.4, 12.5, 13.2, 14.1, 14.4, 15.1, 15.5, 15.6, 15.7_
  - [x] 4.4 Write ApiClient request-construction tests for every endpoint
    - Assert exact path, query, form, and multipart field names per endpoint; no field added, dropped, or renamed
    - **Property 1: API contract immutability**
    - **Validates: Requirements 1.3**

- [x] 5. SidecarManager lifecycle
  - [x] 5.1 Implement `lib/core/sidecar_manager.dart` core lifecycle
    - Select a free localhost port (bind `ServerSocket` to `127.0.0.1:0`, read assigned port, close); `Process.start(sidecarPath, environment: {QPIC_PORT, QPIC_TEMP_DIR, TESSERACT_CMD?})`; poll `GET /api/health` every 500 ms until ready or 30 s; publish `Base_URL`; expose a `status` stream
    - _Requirements: 3.1, 3.2, 3.3, 3.4_
  - [x] 5.2 Implement failure, retry, shutdown, and unexpected-exit handling
    - 30 s timeout failure carrying captured stderr; port-conflict retry up to 3 attempts; graceful terminate then force-kill after 5 s on exit; hook `AppLifecycleState.detached` + `window_manager` close intercept; Windows Job Object/kill-tree; PID-file reap of stale child; transition to EngineStopped on unexpected exit after Ready
    - _Requirements: 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 24.3_
  - [x] 5.3 Write integration test for lifecycle, orphan-freedom, retry, and unexpected exit
    - Start → health → shutdown leaves no surviving sidecar; simulate port conflict and assert retry; kill the process and assert EngineStopped
    - **Property 10: No orphan process**
    - **Validates: Requirements 3.7**

- [x] 6. Application shell, tabs, and startup wiring
  - [x] 6.1 Implement the app shell (top app bar + four tool tabs via `IndexedStack`)
    - Qpic brand, tabs Auto Crop / Manual Crop / Rename Batch / Tools, Help control, segmented Light/Dark/System theme switcher; `IndexedStack` keeps each tool view's state; default selected tab is Auto Crop
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 24.1_
  - [x] 6.2 Wire startup states into the UI
    - Disable tool UI until Ready; blocking startup-failure screen showing captured stderr with a Retry action; non-dismissable engine-stopped banner with Restart
    - _Requirements: 3.4, 3.5, 3.9, 3.10_
  - [x] 6.3 Write widget test for tab behavior
    - Tab switching preserves each view's state; default tab is Auto Crop
    - _Requirements: 4.2, 4.3, 4.4_

- [x] 7. Native integration services
  - [x] 7.1 Implement `lib/core/download_service.dart` (native Save-As, streamed)
    - `file_selector.getSaveLocation` with a suggested filename; stream the engine URL (joined onto Base_URL) to the chosen path without fully buffering; cancel aborts with no file written; failures show a readable error
    - _Requirements: 11.1, 16.1, 16.2, 16.3, 16.4, 16.5_
  - [x] 7.2 Implement `lib/core/file_picker_service.dart`
    - Native open dialog filtered to PDF for crop/tools flows; images + PDF for Rename Batch; load the selected file into the active tool
    - _Requirements: 17.1, 17.2, 17.3_
  - [x] 7.3 Implement `lib/widgets/drop_target.dart` drag-and-drop
    - `desktop_drop` `DropTarget` per tool zone; dropping a PDF loads it; hover state indicates acceptance; non-PDF on a PDF-only target is rejected with a "PDF required" message; Rename target also accepts images
    - _Requirements: 18.1, 18.2, 18.3_

- [x] 8. Checkpoint - core scaffolding wired (shell starts engine, services ready)
  - Ensure all tests pass, ask the user if questions arise.

- [x] 9. Auto Crop feature
  - [x] 9.1 Implement the Auto Crop form and controls with engine bounds
    - Questions/Solutions toggles each with a page-range field; Smart-mode, Online-mode, Answer-sheet toggles; numbering selector (Auto-detect/Q-only/numbered → `marker_style` auto/q/numbered); output config (question/solution prefix, start number, image format PNG/JPG, JPG quality); constrain `dpi` 72–600, `padding` 0–200, `start_number` 1–100000, `jpg_quality` 1–100, prefixes ≤ 10 chars, `image_format` png/jpg
    - _Requirements: 5.1, 5.2, 5.3_
  - [x] 9.2 Implement submit guards and the non-Smart crop path
    - Pre-request guards: Questions on with empty range, Solutions on with empty range, both toggles off → block, send nothing, preserve values, show the matching prompt; on valid submit call `POST /api/crop` with mapped query params + multipart `file`; on success present a download action only for each archive `CropResponse` reports; engine error shows `detail`
    - _Requirements: 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 11.1, 11.2, 11.3_
  - [x] 9.3 Implement crop-archive download wiring
    - `GET /api/crop/download/{job_id}` with `kind` ∈ {combined, questions, solutions} and configured prefixes; Answer-sheet toggle sets `answer_sheet=true`
    - _Requirements: 11.4, 11.5_
  - [x] 9.4 Write widget tests for the crop form guards
    - Empty ranges and nothing-selected block submission and preserve entered values
    - _Requirements: 5.5, 5.6, 5.7_

- [x] 10. Review Canvas geometry and rendering (high-risk)
  - [x] 10.1 Implement `lib/features/review/canvas_geometry.dart`
    - Three coordinate spaces (page-percent ⇄ image-content px ⇄ widget/screen px); `pctToScreen`, `screenToPct` (clamp to 0–100 like web `clamp01`), `segToScreenRect`; zoom factor clamped 0.25–6.0 with fit-width = 100%
    - _Requirements: 8.1, 8.4, 8.6, 8.8, 8.9_
  - [x] 10.2 Write unit tests for CanvasGeometry transforms
    - `screenToPct(pctToScreen(p)) == p` within float tolerance; stored coords stay within 0–100 with end ≥ start across zoom/pan/draw/re-select
    - **Property 3: Coordinate fidelity**
    - **Validates: Requirements 8.1, 8.4, 8.6, 8.8**
  - [x] 10.3 Write unit tests for zoom bounds and pan invariance
    - Displayed zoom always within [0.25, 6.0]; pan never mutates a box's page-percentage coordinates
    - **Property 4: Zoom is bounded**
    - **Validates: Requirements 8.8, 8.9**
  - [x] 10.4 Implement `lib/features/review/review_painter.dart` (`CustomPainter`)
    - Paint the page preview as a `ui.Image` decoded from the engine `preview_url` (server-rendered PNG, no Dart PDF rasterization); draw each on-page Detection_Box as a dashed outline only (no fill), colored by type/flag/editing state; draw the question-number label; draw the in-progress selection rectangle during a drag; draw resize handles and a per-box delete affordance on the active item; `shouldRepaint` keyed to controller state revision
    - _Requirements: 1.5, 6.3, 8.2, 8.3_

- [x] 11. Review Canvas input and box logic (high-risk)
  - [x] 11.1 Implement `segIoU`, `findOverlappingItem`, `nextAutoNumber`, and the min-box guard
    - Port `segIoU` verbatim from the web code; `OVERLAP = 0.6` same-type replace preserving the box's number; `nextAutoNumber(isSolution)` = max same-type number + 1; discard drags smaller than 1.5% of page width or height
    - _Requirements: 8.5, 8.11, 8.13_
  - [x] 11.2 Write unit tests for overlap-replace determinism
    - New same-type box with IoU ≥ 0.6 replaces the existing box (count unchanged, number preserved); stacked distinct boxes do not merge
    - **Property 5: Overlap determinism**
    - **Validates: Requirements 8.11**
  - [x] 11.3 Write unit tests for the min-box guard
    - A drag smaller than 1.5% of page width or height creates no box
    - **Property 7: Min-box guard**
    - **Validates: Requirements 8.5**
  - [x] 11.4 Write unit tests for per-type auto numbering
    - An auto-numbered new box equals the max existing same-type number + 1
    - **Property 8: Per-type numbering**
    - **Validates: Requirements 8.13**
  - [x] 11.5 Implement `GestureDetector` + `MouseRegion` input and hit-testing
    - Hover shows the q-number; drag on empty area draws a box (clamped 0–100); additive re-select appends segments to the editing item; per-box delete; pan translates `panOffset` only (never mutates pct); zoom clamps 0.25–6.0; top-most-precedence hit-test resolves to exactly one box; page navigation clamps target to first..last and shows only that page's preview and boxes
    - _Requirements: 8.3, 8.4, 8.6, 8.7, 8.8, 8.9, 8.10, 8.12_
  - [x] 11.6 Write tests for hit-test single-resolution
    - A pointer inside multiple boxes resolves deterministically to one via top-most precedence
    - **Property 6: Hit-test single-resolution**
    - **Validates: Requirements 8.10**

- [x] 12. Review controller, snap, notes, and engine wiring
  - [x] 12.1 Implement `ReviewController` and `ReviewState`
    - State (`jobId`, `pages`, `items`, `notes`, `currentPageIndex`, `editingIndex`, `zoom`, `pan`, `answerKeyCount`) reused by Smart Auto Crop and Manual Crop; additive re-select semantics (append segments, lock `manualOrder`, set `source=manual`, clear `flagged` and the matching note); "Done" removes any item left with zero segments
    - _Requirements: 6.2, 8.6, 8.7, 8.12, 8.13_
  - [x] 12.2 Implement snap-to-content
    - On box-end with Snap on, call `POST /api/snap` with `{job_id, page, x_start_pct, x_end_pct, y_start_pct, y_end_pct}` and replace the box with the returned rect; on error or unchanged response keep the drawn box
    - _Requirements: 9.1, 9.2, 9.3, 9.4_
  - [x] 12.3 Write unit tests that snap never degrades
    - On snap error or unchanged response, the box equals the user's drawn box
    - **Property 9: Snap never degrades**
    - **Validates: Requirements 9.3, 9.4**
  - [x] 12.4 Implement `review_notes_panel.dart` and Fix actions
    - Render each note's `kind` + `message`; empty list shows the "detection looks complete" advisory; visually distinguish the five kinds (`duplicate`, `gap`, `tiny`, `incomplete`, `low_confidence`); a note with `kind == "incomplete"` and non-null `q_num` shows a Fix action that navigates to the item's page and enters re-select
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_
  - [x] 12.5 Wire Smart analyze entry into the Review Canvas
    - From Auto Crop with Smart on, call `POST /api/analyze` with `dpi, marker_style, has_questions, question_pages, has_answers, answer_pages, use_ai, answer_sheet`; open the canvas regardless of `needs_review`; load each page from its `preview_url`; message whether finalized output includes an answer sheet based on `answer_key_count`; on engine error show `detail` and do not open the canvas
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.7_
  - [-] 12.6 Implement finalize and download from review
    - Build a `FinalizeRequest` from kept auto items plus drawn/re-selected items (each with type and page-percentage region) and the active tool's output config; call `POST /api/finalize`; then offer Combined/Questions/Solutions downloads via the response URLs
    - _Requirements: 6.6, 11.1, 11.2, 11.3, 11.4, 11.5_
  - [x] 12.7 Write widget tests for canvas gesture flows
    - Draw, hover label, additive cross-page re-select, delete box, and page navigation on both supported platforms
    - _Requirements: 8.3, 8.4, 8.6, 8.7, 8.12, 24.2_

- [x] 13. Manual Crop feature
  - [x] 13.1 Implement Manual Crop with independent output fields
    - On open, `POST /api/prepare-manual` (query `dpi`) and open the Review Canvas with an empty item list and all page previews loaded from `preview_url`; hold prefix/start/format/quality independently of Auto Crop; on `prepare-manual` error do not open the canvas and inform the user
    - _Requirements: 7.1, 7.2, 7.3, 7.6_
  - [x] 13.2 Implement manual finalize with guards
    - `POST /api/finalize` with hand-drawn items and the Manual Crop tool's own output config; block finalize and prompt when the item list is empty; retain items on a finalize error so the user can retry
    - _Requirements: 7.4, 7.5, 7.7_

- [x] 14. Checkpoint - review canvas parity (draw/snap/re-select/overlap/zoom/pan/nav)
  - Ensure all tests pass, ask the user if questions arise.

- [x] 15. Rename Batch feature
  - [x] 15.1 Implement Rename Batch controls and live preview
    - Naming-pattern input, start (0–1,000,000), zero-padding (0–12), output format (original/png/jpg/jpeg/webp), JPG quality (1–100); on control change call `POST /api/rename/preview` with `names[], pattern, start, padding` (no image bytes); compute the web UI's token expansion client-side and send stems
    - _Requirements: 12.1, 12.2_
  - [x] 15.2 Implement PDF-to-images and the streamed session flow
    - Add a PDF via `POST /api/rename/pdf-to-images`; rename via `POST /api/rename/session` → chunked `POST /api/rename/session/{id}/files` → `POST /api/rename/session/{id}/finalize` (`pattern, start, padding, names, output_format, jpg_quality`) → `GET /api/rename/session/{id}/download` → `DELETE /api/rename/session/{id}`; surface `detail` on error
    - _Requirements: 12.3, 12.4, 12.5, 12.6_
  - [x] 15.3 Write a test for the rename session flow
    - Session create → files → finalize → download → delete against a running sidecar
    - _Requirements: 12.4, 12.5_

- [x] 16. Tools — Compress
  - [x] 16.1 Implement the Compress panel
    - Level selector (light/balanced/strong/extreme) + optional `target_mb` (> 0); `POST /api/tools/compress` with the PDF and either `level` or `target_mb`; display `original_size`, `compressed_size`, `ratio`; download via the response `download_url`; show `detail` on error
    - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5_

- [x] 17. Tools — Preflight
  - [x] 17.1 Implement the Preflight panel and fix-page-sizes
    - `POST /api/tools/preflight`; render `verdict, page_count, page_sizes, checks, fonts, images, page_details`; when `mixed_page_sizes` is true offer a one-click Fix → `POST /api/tools/preflight/fix-page-sizes` (`target`, `fill_mode` fit/stretch, `skip_pages`); download the normalized PDF via the response `download_url`; show `detail` on error
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6_

- [x] 18. Tools — Edit + OCR
  - [x] 18.1 Implement Edit open and clickable span overlays
    - `POST /api/tools/edit/open` → render each page via its `preview_url`; overlay each `Edit_Span` as a clickable box by converting its `bbox` (PDF points) to screen px using the page `width`/`height` and displayed image size; when `has_text` is false show the "add objects or run OCR to edit existing text" guidance
    - _Requirements: 15.1, 15.2, 15.3, 15.8_
  - [x] 18.2 Implement in-place edit, apply, OCR, and download
    - Click a span to edit its text in place; `POST /api/tools/edit/apply` with the `operations`; `POST /api/tools/edit/ocr` with `languages` and `dpi`; `GET /api/tools/edit/download/{job_id}`
    - _Requirements: 15.4, 15.5, 15.6, 15.7_
  - [x] 18.3 Write widget tests for the Tools panels
    - Compress/Preflight/Edit render the response fields and wire the correct endpoints
    - _Requirements: 13.3, 14.2, 15.3_

- [x] 19. Menus, Help, and shortcuts
  - [x] 19.1 Implement the platform menu bar and edit/zoom shortcuts
    - `PlatformMenuBar` (macOS app menu + Edit + Help) and the Windows equivalent; Edit menu cut/copy/paste/select-all reaching focused text fields; zoom shortcuts (Ctrl/Cmd +, -, 0) driving the active document view's zoom
    - _Requirements: 19.3, 19.4_
  - [x] 19.2 Implement the in-app Help walkthrough
    - A `HelpScreen` reproducing the How_To_Content (overall guide, How to Crop, How to Rename Batch) as native Flutter with no external links, mirroring the web walkthrough tabs
    - _Requirements: 19.1, 19.2, 19.5_

- [x] 20. Checkpoint - all four tools functional via automated tests
  - Ensure all tests pass, ask the user if questions arise.

- [x] 21. Packaging and installers
  - [x] 21.1 macOS packaging: embed sidecar, build `.dmg`, signing/notarization hooks
    - `flutter build macos`; copy the PyInstaller sidecar onedir into `Qpic.app/Contents/Resources/sidecar/` so `paths.dart` resolves it; entitlements allowing child-process spawn with loopback-only network; package into a `.dmg`; read `MAC_CERT_IDENTITY`/`AC_NOTARY_PROFILE` to codesign + notarize when present, unsigned when absent
    - _Requirements: 21.1, 21.3, 21.4, 21.6, 21.7_
  - [x] 21.2 Windows packaging: embed sidecar, build MSIX/NSIS, Authenticode hook
    - `flutter build windows`; copy the sidecar onedir into the runner's `sidecar/` subfolder; build MSIX (default) or NSIS embedding `sidecar/` and bundled Tesseract; read `WIN_CERT_PATH`/`WIN_CERT_PASSWORD` to `signtool sign` app, sidecar, and installer when present, unsigned when absent
    - _Requirements: 21.2, 21.3, 21.5, 21.6, 21.7_
  - [x] 21.3 Write an integration test that the embedded sidecar path resolves and starts
    - Resolve the per-OS sidecar path and confirm start → health on both packaged and dev paths
    - _Requirements: 21.3, 24.3_

- [x] 22. Build scripts, dev workflow, and documentation
  - [x] 22.1 Create `build_desktop_flutter.sh` and `build_desktop_flutter.ps1`
    - Steps: `pip install -r requirements.txt -r requirements-desktop.txt`; `python scripts/vendor_tesseract.py --langs eng,hin,osd`; `pyinstaller packaging/sidecar.spec --noconfirm`; `flutter build macos|windows`; embed sidecar; package `.dmg` / MSIX|NSIS; optional sign/notarize when cert env vars are set; these replace `build_desktop.sh`, `build_desktop.bat`, and `build_desktop_qt.sh`
    - _Requirements: 21.4, 21.5, 22.1, 22.2_
  - [x] 22.2 Update the README "Desktop app" section and add retirement guidance
    - Document the Flutter build and run-from-source flow (dev `python -m packaging.sidecar` fallback); leave all non-desktop README sections unchanged; add written guidance recommending retirement of `desktop.py`/`desktop_qt.py` after the Flutter build is validated on both OSes, with reasoning
    - _Requirements: 22.3, 22.4, 22.5_

- [x] 23. CI workflow update
  - [x] 23.1 Update `.github/workflows/build-desktop.yml`
    - Keep the `macos-latest` + `windows-latest` matrix; install and vendor Tesseract on each runner; build the PyInstaller sidecar; install Flutter (`subosito/flutter-action`) and enable desktop; build the Flutter app; embed the sidecar and package the per-OS installer; sign/notarize when secrets are present; attach packaged installers to a GitHub Release on a version tag
    - _Requirements: 23.1, 23.2, 23.3, 23.4, 23.5, 23.6_

- [x] 24. Final checkpoint - installers build on both OSes; review-canvas parity gate met
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- No task adds, removes, or modifies any file under `app/`; the engine and all API contracts stay byte-for-byte unchanged. The Flutter app is purely a new HTTP client with zero engine logic in Dart, and page previews are always server-rendered PNGs.
- Tasks marked with `*` are optional test sub-tasks and can be skipped for a faster MVP. They are never implemented automatically.
- Each task references the specific requirement clauses it implements for traceability.
- Property-based test sub-tasks each reference one correctness property from the design and the requirement clauses it validates. All 11 design properties are covered (Properties 1–11).
- Checkpoints provide incremental validation; the review canvas (Tasks 10–13) is the high-risk parity gate that must reach feature parity before the feature is considered done.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "3.1"] },
    { "id": 1, "tasks": ["1.2", "3.2", "3.3", "4.1", "7.2", "7.3"] },
    { "id": 2, "tasks": ["1.3", "3.4", "4.2", "4.3", "6.1", "10.1", "11.1"] },
    { "id": 3, "tasks": ["4.4", "5.1", "6.3", "7.1", "9.1", "10.2", "10.3", "10.4", "11.2", "11.3", "11.4", "15.1", "16.1", "17.1", "18.1", "19.1", "19.2"] },
    { "id": 4, "tasks": ["5.2", "6.2", "9.2", "11.5", "15.2", "18.2", "18.3"] },
    { "id": 5, "tasks": ["5.3", "9.3", "9.4", "11.6", "12.1", "15.3"] },
    { "id": 6, "tasks": ["12.2", "12.4", "12.5", "12.7", "13.1"] },
    { "id": 7, "tasks": ["12.3", "12.6"] },
    { "id": 8, "tasks": ["13.2", "21.1", "21.2"] },
    { "id": 9, "tasks": ["21.3", "22.1", "22.2"] },
    { "id": 10, "tasks": ["23.1"] }
  ]
}
```
