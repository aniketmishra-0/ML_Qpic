# Requirements Document

## Introduction

Qpic is a PDF MCQ-cropping tool. Its engine is a Python FastAPI backend (`app/`) that runs a text → OCR → AI-vision detection pipeline, crops and stitches questions/solutions, builds ZIP and answer-sheet outputs, and exposes PDF power-tools (Compress / Edit / Preflight) via PyMuPDF. Today the engine is presented on the desktop through two web-shell launchers: `desktop.py` (pywebview) and `desktop_qt.py` (PySide6/Qt WebEngine), both of which boot the FastAPI server on a private localhost port and host the existing web UI (`static/index.html`, `static/edit.html`, `static/edit.js`).

This feature replaces those web-shell launchers with a native Flutter desktop application for macOS and Windows. The Flutter app starts the unchanged FastAPI engine as a packaged sidecar process, waits for it to become healthy, and drives all functionality against the existing localhost HTTP API. The Flutter app faithfully recreates every behavior of the existing web UI — including the high-risk review canvas — as native Flutter, with no loss of features.

This is a UI/window-technology replacement only. The FastAPI engine, the detection pipeline, crop/stitch logic, the Tools backend, the offline-Tesseract approach, and all API contracts (paths, parameters, request/response shapes) remain exactly as they are today. The Flutter app is purely a new client of the same API.

## Glossary

- **Qpic_Engine**: The existing Python FastAPI backend in `app/` (routers, services, detector pipeline, schemas). The source of truth for all processing. Unchanged by this feature.
- **Flutter_App**: The new Flutter desktop application (macOS + Windows) that replaces the pywebview/Qt window shells.
- **Sidecar**: The Qpic_Engine packaged as a standalone executable (via PyInstaller, one per OS) that the Flutter_App launches as a child process.
- **Sidecar_Manager**: The component within the Flutter_App responsible for the Sidecar lifecycle (port selection, launch, health wait, shutdown, error reporting).
- **Base_URL**: The `http://127.0.0.1:{port}` address the Sidecar listens on, used as the root for all API calls.
- **Health_Endpoint**: The existing `GET /api/health` endpoint that reports engine readiness, Tesseract availability, and AI availability.
- **API_Client**: The component within the Flutter_App that issues HTTP requests to the Qpic_Engine against the Base_URL.
- **Review_Canvas**: The interactive page-preview surface where detection boxes are overlaid, drawn, re-selected, deleted, and panned/zoomed. The highest-risk component to reach parity on.
- **Detection_Box**: A rectangular region on a page preview representing a detected or user-drawn question/solution crop, expressed in page-percentage coordinates.
- **Review_Note**: A human-readable advisory item returned by the engine (`cut-off`/incomplete, duplicate, numbering gap, tiny, low_confidence) shown during review, some with a one-click Fix action.
- **Tools_Tab**: The UI area hosting the three PyMuPDF-backed tools: Compress, Edit, and Preflight.
- **Edit_Span**: An editable text run on a page in the Edit tool, returned with geometry and style by `POST /api/tools/edit/open`.
- **Tesseract_Bundle**: The vendored, self-contained Tesseract (binary + libraries + `eng`/`hin`/`osd` language data) shipped with the Sidecar for offline OCR.
- **Tesseract_Lookup_Order**: The runtime resolution order `TESSERACT_CMD` env → bundled copy → system install → PATH, implemented today in `tesseract_locator.py`.
- **Writable_Data_Dir**: The per-user, writable directory for temp crop jobs (`~/Library/Application Support/Qpic` on macOS, `%LOCALAPPDATA%\Qpic` on Windows).
- **Native_Save_Dialog**: The OS "Save As" dialog used to write downloaded files to a user-chosen path.
- **CI_Workflow**: The GitHub Actions workflow `.github/workflows/build-desktop.yml` that builds and packages the desktop app on macOS and Windows.
- **Installer**: The packaged distributable: `.app`/`.dmg` for macOS, `.msi` or NSIS for Windows.
- **How_To_Content**: The in-app "How to Use" walkthrough content reproduced from the web UI, with no external links.

## Requirements

### Requirement 1: Engine and API contract preservation (non-goal guard)

**User Story:** As a maintainer, I want the FastAPI engine and its API contracts to remain unchanged, so that the app's purpose and behavior stay 100% identical and the Flutter app is purely a new client.

#### Acceptance Criteria

1. THE Flutter_App SHALL communicate with the Qpic_Engine exclusively through the existing HTTP API exposed under the `/api` prefix.
2. THE Qpic_Engine source tree under `app/` (routers, services, detector pipeline, schemas) SHALL have no files added, removed, or modified by this feature, preserving a byte-for-byte baseline.
3. THE Flutter_App SHALL use the existing API endpoint paths, query-parameter names, form-field names, and request/response field names and structures without adding, removing, or renaming any of them.
4. THE Flutter_App SHALL implement zero engine processing logic in Dart, including detection, OCR, crop/stitch, answer-key, and PDF-tool processing, and SHALL delegate all such processing to the Qpic_Engine.
5. WHERE page previews of a PDF are displayed, THE Flutter_App SHALL render server-produced PNG images obtained from the Qpic_Engine rather than rasterizing PDFs in Dart.
6. THE Flutter_App SHALL preserve the existing offline OCR behavior using the vendored Tesseract approach and the Tesseract_Lookup_Order.
7. WHILE Online mode is enabled, THE Flutter_App SHALL permit only the non-loopback outbound calls that the Qpic_Engine already makes to the AI tier.
8. WHILE Online mode is disabled, THE Flutter_App SHALL make zero non-loopback outbound calls.

### Requirement 2: Sidecar packaging

**User Story:** As a maintainer, I want the FastAPI engine bundled as a per-OS sidecar binary, so that the Flutter app can run the unchanged engine without a separate Python install.

#### Acceptance Criteria

1. THE Sidecar SHALL be produced by packaging the existing FastAPI application using PyInstaller.
2. THE Sidecar SHALL include the static web assets, the `app` package, and all Python runtime dependencies imported by the Qpic_Engine, such that the Sidecar starts with no missing-module errors.
3. THE Sidecar SHALL embed the Tesseract_Bundle so that OCR functions without a separate Tesseract installation.
4. THE build process SHALL produce a macOS Sidecar executable and a Windows Sidecar executable.
5. WHERE the Sidecar is launched inside the packaged Flutter_App, THE Sidecar SHALL resolve its bundled resources (static assets, `app` package, Tesseract_Bundle) from the executable's own bundled location rather than from the working directory or absolute environment paths.
6. WHEN the Sidecar is started on a host that has no separate Python installation, THE Sidecar SHALL start and report ready through the Health_Endpoint.
7. IF a bundled resource required by the Sidecar is missing, THEN THE Sidecar SHALL fail to start with an error identifying the missing resource and SHALL leave no partially running engine.

### Requirement 3: Sidecar lifecycle management

**User Story:** As a user, I want the engine to start and stop automatically and cleanly, so that I just open the app and it works without orphaned processes or manual steps.

#### Acceptance Criteria

1. WHEN the Flutter_App launches, THE Sidecar_Manager SHALL select a free localhost port in the range 1024 to 65535 before starting the Sidecar.
2. WHEN the Flutter_App launches, THE Sidecar_Manager SHALL start the Sidecar bound to `127.0.0.1` on the selected port.
3. WHEN the Sidecar has started, THE Sidecar_Manager SHALL poll the Health_Endpoint every 500 milliseconds until it reports ready or until a 30-second startup timeout elapses.
4. WHEN the Health_Endpoint reports ready, THE Flutter_App SHALL set the Base_URL to `http://127.0.0.1:{selected_port}` and enable the UI against that Base_URL.
5. IF the Sidecar fails to become ready within the 30-second startup timeout, THEN THE Flutter_App SHALL display a human-readable startup-failure message identifying that the engine did not start.
6. WHEN the Flutter_App exits, THE Sidecar_Manager SHALL request graceful termination of the Sidecar process and SHALL force-kill the process if it has not exited within 5 seconds.
7. WHEN the Flutter_App exits, THE Sidecar_Manager SHALL leave no orphaned Sidecar process running.
8. IF the selected port becomes unavailable before the Sidecar binds to it, THEN THE Sidecar_Manager SHALL select another free localhost port in the range 1024 to 65535 and retry the Sidecar launch, up to a maximum of 3 retry attempts.
9. IF the 3 port-conflict retry attempts are exhausted, THEN THE Flutter_App SHALL display a human-readable startup-failure message and SHALL leave the UI disabled.
10. WHEN the Sidecar terminates unexpectedly after having reported ready, THE Flutter_App SHALL disable the UI and SHALL display a human-readable message that the engine stopped.
11. THE Sidecar_Manager SHALL set the engine temp directory to a per-user Writable_Data_Dir before starting the Sidecar.

### Requirement 4: Application shell, app bar, tool tabs, and themes

**User Story:** As a user, I want the same Acrobat-style top app bar, tool tabs, and theme switcher, so that the app feels and works exactly like the web UI.

#### Acceptance Criteria

1. THE Flutter_App SHALL present a top app bar containing the Qpic brand, the tool tabs, a Help control, and a theme switcher.
2. THE Flutter_App SHALL provide exactly four tool tabs labeled Auto Crop, Manual Crop, Rename Batch, and Tools.
3. WHEN a user selects a tool tab, THE Flutter_App SHALL show only that tool's view, hide the other three tool views, and mark the selected tab active.
4. WHEN the Flutter_App launches, THE Flutter_App SHALL select the Auto Crop tool tab as the default.
5. THE Flutter_App SHALL provide a theme switcher offering Light, Dark, and System options.
6. WHEN a user selects a theme option, THE Flutter_App SHALL apply that theme's palette to the interface without requiring an application restart.
7. WHILE the theme is set to System, THE Flutter_App SHALL follow the operating system's light/dark preference, including changes made while the Flutter_App is running.
8. WHEN a user selects a theme option, THE Flutter_App SHALL persist that selection so it is retained across application restarts.
9. WHEN the Flutter_App launches for the first time with no persisted theme, THE Flutter_App SHALL default the theme to System, and WHEN a persisted theme exists, THE Flutter_App SHALL re-apply that theme on launch.

### Requirement 5: Auto Crop — options, toggles, and direct crop

**User Story:** As a user, I want the Auto Crop tool with all its options and toggles, so that I can crop a PDF exactly as I do in the web UI.

#### Acceptance Criteria

1. THE Flutter_App SHALL provide a Questions toggle and a Solutions toggle, each with an associated page-range input.
2. THE Flutter_App SHALL provide a Smart-mode toggle, an Online-mode toggle, an Answer-sheet toggle, and a question-numbering selector offering Auto-detect, Q-only, and numbered options.
3. THE Flutter_App SHALL provide output configuration fields for question prefix, solution prefix, start number, image format (PNG or JPG), and JPG quality, and SHALL constrain each control to the engine's accepted bounds: `dpi` 72–600, `padding` 0–200, `start_number` 1–100000, `jpg_quality` 1–100, the question prefix and solution prefix each to a maximum length of 10 characters, `marker_style` to one of `auto`, `q`, or `numbered`, and `image_format` to one of `png` or `jpg`.
4. WHEN a user submits a non-Smart-mode crop, THE API_Client SHALL call `POST /api/crop` with the configured query parameters (`dpi`, `padding`, `marker_style`, `has_questions`, `question_pages`, `has_answers`, `answer_pages`, `question_prefix`, `solution_prefix`, `start_number`, `image_format`, `jpg_quality`, `use_ai`, `answer_sheet`) mapped from their corresponding UI controls and the uploaded PDF.
5. IF the Questions toggle is on and the question page-range is empty, THEN THE Flutter_App SHALL block submission, send no request, preserve the entered values, and prompt the user to provide question pages.
6. IF the Solutions toggle is on and the answer page-range is empty, THEN THE Flutter_App SHALL block submission, send no request, preserve the entered values, and prompt the user to provide answer pages.
7. IF both the Questions toggle and the Solutions toggle are off, THEN THE Flutter_App SHALL block submission, send no request, preserve the entered values, and prompt the user that at least one of questions or solutions must be selected (ERR_NOTHING_SELECTED).
8. IF the Qpic_Engine returns an error response for a crop request, THEN THE Flutter_App SHALL display the engine-provided error detail to the user.
9. WHEN a crop completes successfully, THE Flutter_App SHALL present a download action only for each archive (combined, questions-only, solutions-only) that the CropResponse reports as available.

### Requirement 6: Smart Auto Crop — analyze and review entry

**User Story:** As a user, I want Smart mode to analyze the PDF and open the review canvas, so that I can verify and hand-fix detections before downloading.

#### Acceptance Criteria

1. WHEN a user submits a crop with Smart mode on, THE API_Client SHALL call `POST /api/analyze` with the uploaded PDF and the parameters `dpi`, `marker_style`, `has_questions`, `question_pages`, `has_answers`, `answer_pages`, `use_ai`, and `answer_sheet`.
2. WHEN the analyze response is received, THE Flutter_App SHALL open the Review_Canvas populated with the returned page previews, detected items, and Review_Notes, regardless of the value of `needs_review`.
3. WHEN displaying a page in the Review_Canvas, THE Flutter_App SHALL load that page's preview by requesting the engine-provided `preview_url` against the Base_URL.
4. WHEN the analyze response reports `answer_key_count` greater than 0, THE Flutter_App SHALL inform the user that the finalized download WILL include an answer sheet.
5. WHEN the analyze response reports `answer_key_count` equal to 0, THE Flutter_App SHALL inform the user that the finalized download will NOT include an answer sheet.
6. WHEN a user finalizes a reviewed item set, THE API_Client SHALL call `POST /api/finalize` with the job id and an items payload containing the kept auto items plus the user-drawn or re-selected items, each carrying its type (question or solution) and page-percentage region, together with the output configuration (`dpi`, `padding`, `question_prefix`, `solution_prefix`, `start_number`, `image_format`, `jpg_quality`, `answer_sheet`).
7. IF the Qpic_Engine returns an error response for an analyze request, THEN THE Flutter_App SHALL display the engine-provided error detail and SHALL NOT open the Review_Canvas.

### Requirement 7: Manual Crop tool

**User Story:** As a user, I want the Manual Crop tool that opens every page for hand-drawing crops, so that I can crop a PDF with no auto-detection.

#### Acceptance Criteria

1. WHEN a user opens a PDF in Manual Crop, THE API_Client SHALL call `POST /api/prepare-manual` with the uploaded PDF.
2. WHEN the prepare-manual response is received, THE Flutter_App SHALL open the Review_Canvas with an empty item list and SHALL load each page preview from its engine-provided `preview_url` against the Base_URL.
3. THE Manual Crop tool SHALL read its own prefix, start-number, image format (PNG or JPG), and JPG quality (1–100) fields independently of the Auto Crop tool, such that changing one tool's field does not alter the other tool's field.
4. WHEN a user finalizes a manual crop, THE API_Client SHALL call `POST /api/finalize` with the job id, the hand-drawn items, and the Manual Crop tool's own `question_prefix`, `solution_prefix`, `start_number`, `image_format`, and `jpg_quality` values.
5. IF the manual item list is empty, THEN THE Flutter_App SHALL block finalize and SHALL prompt the user to draw at least one crop.
6. IF the `POST /api/prepare-manual` request returns an error response (for example, a non-PDF upload rejected with HTTP 400), THEN THE Flutter_App SHALL NOT open the Review_Canvas and SHALL inform the user of the error.
7. IF the `POST /api/finalize` request returns an error response, THEN THE Flutter_App SHALL retain the hand-drawn items so the user can retry.

### Requirement 8: Review canvas — feature parity (high-risk)

**User Story:** As a user, I want the review canvas to behave exactly like the web canvas, so that I can verify, draw, fix, and delete crop boxes without any loss of capability.

#### Acceptance Criteria

1. THE Review_Canvas SHALL express Detection_Box coordinates as page percentages, where x is 0–100 of page width and y is 0–100 of page height, with end values greater than or equal to start values.
2. THE Review_Canvas SHALL render the current page preview image with each Detection_Box drawn as an overlay positioned by its page-percentage coordinates.
3. WHEN a user hovers over a Detection_Box, THE Review_Canvas SHALL display that box's question number.
4. WHEN a user drags a region on empty canvas area whose width is at least 1.5% of page width and whose height is at least 1.5% of page height, THE Review_Canvas SHALL draw a new Detection_Box from the dragged region with its coordinates clamped to the range 0–100.
5. IF a user's drag produces a region smaller than 1.5% of page width or 1.5% of page height, THEN THE Review_Canvas SHALL discard the drag and SHALL NOT create a Detection_Box.
6. WHEN a user re-selects an existing Detection_Box, THE Review_Canvas SHALL allow that box's region to be redrawn and updated with its coordinates clamped to the range 0–100.
7. WHEN a user deletes a Detection_Box, THE Review_Canvas SHALL remove that box from the item set.
8. WHEN a user pans the Review_Canvas, THE Review_Canvas SHALL translate the displayed page without altering any Detection_Box page-percentage coordinates and SHALL keep the overlays aligned to page content.
9. WHEN a user zooms the Review_Canvas, THE Review_Canvas SHALL scale the displayed page to a factor clamped between 25% and 600% with fit-width equal to 100%, and SHALL keep Detection_Box overlays aligned to page content.
10. WHEN a user points at a location that falls within more than one Detection_Box, THE Review_Canvas SHALL resolve the hit-test to exactly one box using deterministic top-most precedence.
11. WHEN a user draws a new box that overlaps an existing same-type Detection_Box with an intersection-over-union of at least 0.6, THE Review_Canvas SHALL replace the existing box rather than create a duplicate, preserving that box's number.
12. WHEN a user navigates between pages in review, THE Review_Canvas SHALL clamp the target to the range from the first page to the last page and SHALL display only the selected page's preview and that page's Detection_Boxes.
13. WHEN a user marks a new box as a Question or a Solution before drawing, THE Review_Canvas SHALL assign that type and SHALL set the box's number to the highest existing number of the same type plus 1.

### Requirement 9: Snap to content

**User Story:** As a user, I want a roughly drawn box to tighten to the content inside it, so that my manual crops match the web UI's snap behavior.

#### Acceptance Criteria

1. WHEN a user requests snap for a drawn box, THE API_Client SHALL call `POST /api/snap` with the job id, the page number, and the box's `x_start_pct`, `x_end_pct`, `y_start_pct`, and `y_end_pct` coordinates.
2. WHEN the snap response is received, THE Review_Canvas SHALL update the box to the returned `x_start_pct`, `x_end_pct`, `y_start_pct`, and `y_end_pct` coordinates.
3. IF the snap response returns the box coordinates unchanged, THEN THE Review_Canvas SHALL keep the user's drawn box without degrading it.
4. IF the `POST /api/snap` request returns an error response, THEN THE Review_Canvas SHALL keep the user's drawn box unchanged.

### Requirement 10: Review notes and Fix actions

**User Story:** As a user, I want review notes and their Fix actions wired to the same endpoints, so that I can resolve cut-offs, duplicates, gaps, and missing options as I do in the web UI.

#### Acceptance Criteria

1. WHEN the analyze response is received, THE Flutter_App SHALL display each Review_Note from the response, showing its `kind` and `message`.
2. IF the analyze response contains an empty notes list, THEN THE Flutter_App SHALL display a "detection looks complete" advisory.
3. WHERE a Review_Note has `kind` equal to `incomplete` and a non-null `q_num`, THE Flutter_App SHALL present a Fix action for that note.
4. WHEN a user activates a Fix action, THE Review_Canvas SHALL navigate to the referenced item's page and begin re-selecting its region.
5. THE Flutter_App SHALL visually distinguish the five Review_Note kinds (`duplicate`, `gap`, `tiny`, `incomplete`, `low_confidence`) consistent with the web UI.

### Requirement 11: Output download options

**User Story:** As a user, I want to choose Combined, Questions, or Solutions output with prefixes and the answer-sheet toggle, so that I get exactly the archive I want.

#### Acceptance Criteria

1. WHEN a crop or finalize completes, THE Flutter_App SHALL offer download of the Combined archive using the response `download_url`.
2. WHERE the response includes a non-null `questions_download_url`, THE Flutter_App SHALL offer a Questions-only download.
3. WHERE the response includes a non-null `solutions_download_url`, THE Flutter_App SHALL offer a Solutions-only download.
4. WHEN a user downloads an archive, THE API_Client SHALL request `GET /api/crop/download/{job_id}` with the `kind` parameter set to one of `combined`, `questions`, or `solutions`, and the configured `question_prefix` and `solution_prefix` parameters.
5. WHILE the Answer-sheet toggle is on, THE Flutter_App SHALL set the engine's `answer_sheet` parameter to true so the answer sheet is requested for inclusion.

### Requirement 12: Rename Batch tool

**User Story:** As a user, I want the Rename Batch tool, so that I can rename a batch of images or PDF pages and download them as a ZIP exactly as in the web UI.

#### Acceptance Criteria

1. THE Flutter_App SHALL provide naming-pattern input, a start-number input constrained to 0–1000000, a zero-padding input constrained to 0–12 digits, an output-format selector offering original, png, jpg, jpeg, and webp, and a JPG-quality input constrained to 1–100 for batch renaming.
2. WHEN a user adjusts naming controls, THE API_Client SHALL call `POST /api/rename/preview` with the `names`, `pattern`, `start`, and `padding` form fields to show a live before/after list without uploading image bytes.
3. WHEN a user adds a PDF to the rename batch, THE API_Client SHALL call `POST /api/rename/pdf-to-images` to convert the PDF pages into images.
4. WHEN a user renames a batch, THE API_Client SHALL use the session flow: `POST /api/rename/session`, then `POST /api/rename/session/{id}/files`, then `POST /api/rename/session/{id}/finalize` with the `pattern`, `start`, `padding`, `names`, `output_format`, and `jpg_quality` fields, then `GET /api/rename/session/{id}/download`.
5. WHEN a rename session download completes, THE API_Client SHALL call `DELETE /api/rename/session/{id}` to release the session.
6. IF a rename request returns an error response, THEN THE Flutter_App SHALL display the engine-provided error detail to the user.

### Requirement 13: Tools tab — Compress

**User Story:** As a user, I want the Compress tool, so that I can shrink a PDF by level or target size and download the result.

#### Acceptance Criteria

1. THE Flutter_App SHALL provide a Compress panel with a level selector offering light, balanced, strong, and extreme, and an optional target-size-in-MB input constrained to values greater than 0.
2. WHEN a user runs Compress, THE API_Client SHALL call `POST /api/tools/compress` with the PDF and either the chosen `level` or the `target_mb` value.
3. WHEN the compress response is received, THE Flutter_App SHALL display the `original_size`, the `compressed_size`, and the `ratio`.
4. WHEN a user downloads the compressed PDF, THE API_Client SHALL request the `download_url` returned in the compress response against the Base_URL.
5. IF a compress request returns an error response, THEN THE Flutter_App SHALL display the engine-provided error detail to the user.

### Requirement 14: Tools tab — Preflight

**User Story:** As a user, I want the Preflight tool, so that I can inspect a PDF and optionally normalize its page sizes.

#### Acceptance Criteria

1. WHEN a user runs Preflight, THE API_Client SHALL call `POST /api/tools/preflight` with the PDF.
2. WHEN the preflight response is received, THE Flutter_App SHALL display the `verdict`, `page_count`, `page_sizes`, `checks`, `fonts`, `images`, and `page_details`.
3. WHERE the preflight response reports `mixed_page_sizes` as true, THE Flutter_App SHALL offer a one-click "Fix page sizes" action.
4. WHEN a user runs the page-size fix, THE API_Client SHALL call `POST /api/tools/preflight/fix-page-sizes` with the `target`, `fill_mode` (one of `fit` or `stretch`), and `skip_pages` values.
5. WHEN a user downloads the normalized PDF, THE API_Client SHALL request the `download_url` returned in the preflight-fix response against the Base_URL.
6. IF a preflight or page-size-fix request returns an error response, THEN THE Flutter_App SHALL display the engine-provided error detail to the user.

### Requirement 15: Tools tab — Edit and OCR

**User Story:** As a user, I want the Edit tool with clickable text-span boxes over page previews and a Run-OCR action, so that I can edit PDF text and make scans searchable like the web UI.

#### Acceptance Criteria

1. WHEN a user opens a PDF in the Edit tool, THE API_Client SHALL call `POST /api/tools/edit/open` and receive editable spans and page geometry.
2. THE Edit tool SHALL render each page preview by loading its engine-provided `preview_url` against the Base_URL.
3. THE Edit tool SHALL overlay each Edit_Span as a clickable box positioned by its geometry over the corresponding page preview.
4. WHEN a user clicks an Edit_Span, THE Edit tool SHALL allow that span's text to be edited in place.
5. WHEN a user applies edits, THE API_Client SHALL call `POST /api/tools/edit/apply` with the job id and the edit operations.
6. WHEN a user runs OCR, THE API_Client SHALL call `POST /api/tools/edit/ocr` with the PDF and the language and DPI parameters.
7. WHEN a user downloads the edited or OCR'd PDF, THE API_Client SHALL request `GET /api/tools/edit/download/{job_id}`.
8. WHERE an opened PDF has no selectable text, THE Edit tool SHALL inform the user that adding objects or running OCR is required to edit existing text.

### Requirement 16: Native Save-As for downloads

**User Story:** As a user, I want a native Save-As dialog for downloads, so that files reach my chosen folder since the sidecar cannot trigger browser downloads.

#### Acceptance Criteria

1. WHEN a user initiates a download of an engine-produced file, THE Flutter_App SHALL present a Native_Save_Dialog with a suggested filename.
2. WHEN a user confirms a save path, THE Flutter_App SHALL fetch the file from the Base_URL and write it to the chosen path.
3. WHEN saving a downloaded file, THE Flutter_App SHALL stream the file to disk so that large archives are saved without exhausting memory.
4. IF a user cancels the Native_Save_Dialog, THEN THE Flutter_App SHALL abort the save without writing a file.
5. IF a download fails, THEN THE Flutter_App SHALL display a readable error message to the user.

### Requirement 17: Native file open

**User Story:** As a user, I want native file pickers for opening files, so that I can select PDFs and images for the crop, rename, and tools flows.

#### Acceptance Criteria

1. WHEN a user opens the file picker in a crop or tools flow, THE Flutter_App SHALL present a native open dialog filtered to PDF files.
2. WHEN a user opens the file picker in the Rename Batch flow, THE Flutter_App SHALL present a native open dialog allowing image files and PDF files.
3. WHEN a user selects a file in a native open dialog, THE Flutter_App SHALL load that file into the active tool.

### Requirement 18: Drag-and-drop upload

**User Story:** As a user, I want to drag a PDF onto the window to upload it, so that I keep the drag-and-drop convenience the web UI offers.

#### Acceptance Criteria

1. WHEN a user drops a PDF file onto a tool's drop target, THE Flutter_App SHALL load that PDF into the active tool.
2. WHILE a file is dragged over a drop target, THE Flutter_App SHALL indicate that the target will accept the drop.
3. IF a user drops a file of an unsupported type onto a PDF-only drop target, THEN THE Flutter_App SHALL reject the file and inform the user that a PDF is required.

### Requirement 19: Application menus, Help, and shortcuts

**User Story:** As a user, I want app menus with in-app Help and standard edit/zoom shortcuts, so that I get the same guidance and keyboard behavior as the desktop shells provide.

#### Acceptance Criteria

1. THE Flutter_App SHALL provide an in-app Help action that opens the How_To_Content walkthrough.
2. THE How_To_Content SHALL be reproduced within the Flutter_App without external links.
3. THE Flutter_App SHALL provide standard edit shortcuts (cut, copy, paste, select all) for text fields.
4. THE Flutter_App SHALL provide zoom shortcuts for the document views consistent with the desktop shells.
5. THE Flutter_App SHALL provide Help entries for the overall guide, cropping, and rename batch, mirroring the web walkthrough tabs.

### Requirement 20: Offline Tesseract bundling

**User Story:** As a maintainer, I want Tesseract bundled and discovered with the same lookup order, so that OCR stays fully offline on both operating systems.

#### Acceptance Criteria

1. THE packaged Flutter_App SHALL include the Tesseract_Bundle with the Tesseract binary, its required libraries, and the `eng`, `hin`, and `osd` language data on macOS and Windows.
2. THE Sidecar SHALL resolve the Tesseract binary using the Tesseract_Lookup_Order: `TESSERACT_CMD` environment variable, then the bundled copy, then a system install, then PATH.
3. WHEN the bundled Tesseract is used, THE Sidecar SHALL point its language-data path at the bundled `tessdata`.
4. WHILE no AI key is configured and Online mode is off, THE Qpic_Engine SHALL perform OCR using only the bundled Tesseract with no network access.

### Requirement 21: Packaging and installers

**User Story:** As a maintainer, I want signed-ready installers for macOS and Windows, so that users can install the app with the sidecar and Tesseract correctly embedded.

#### Acceptance Criteria

1. THE build process SHALL produce a macOS distributable as a `.app` bundle packaged into a `.dmg`.
2. THE build process SHALL produce a Windows installer as an `.msi` or NSIS package.
3. THE macOS and Windows Installers SHALL embed the Sidecar and the Tesseract_Bundle so that both are discoverable at runtime inside the installed application.
4. THE build process SHALL provide configuration hooks for macOS code signing and notarization where certificates and keys are supplied by the maintainer.
5. THE build process SHALL provide configuration hooks for Windows Authenticode signing where a certificate is supplied by the maintainer.
6. THE Flutter desktop project SHALL include `pubspec.yaml`, a `lib/` directory, a `macos/` directory, and a `windows/` directory.
7. THE deliverables SHALL include the PyInstaller sidecar build configuration and scripts for each operating system.

### Requirement 22: Build and run-from-source scripts

**User Story:** As a developer, I want run-from-source instructions and build scripts, so that I can develop and build the Flutter desktop app in place of the legacy shell scripts.

#### Acceptance Criteria

1. THE deliverables SHALL include build scripts that build the Sidecar and the Flutter desktop app and package the Installers, replacing `build_desktop.sh`, `build_desktop.bat`, and the Qt build variant.
2. THE deliverables SHALL include developer instructions for running the Flutter_App and Sidecar from source.
3. THE README "Desktop app" section SHALL be updated to document the Flutter build.
4. THE README sections that document non-desktop features SHALL remain unchanged.
5. THE deliverables SHALL include written guidance on whether to retire `desktop.py` and `desktop_qt.py` and the reasoning for the recommendation.

### Requirement 23: CI workflow update

**User Story:** As a maintainer, I want the CI workflow to build the full Flutter desktop app on both OSes, so that releases are produced automatically with the sidecar and Tesseract embedded.

#### Acceptance Criteria

1. THE CI_Workflow SHALL run jobs on `macos-latest` and `windows-latest`.
2. THE CI_Workflow SHALL install and vendor Tesseract on each runner before building the Sidecar.
3. THE CI_Workflow SHALL build the PyInstaller Sidecar on each runner.
4. THE CI_Workflow SHALL build the Flutter desktop app on each runner.
5. THE CI_Workflow SHALL package the per-OS Installers on each runner.
6. WHEN the CI_Workflow runs for a version tag, THE CI_Workflow SHALL attach the packaged Installers to a GitHub Release.

### Requirement 24: Cross-platform consistency

**User Story:** As a user on either macOS or Windows, I want the app to work the same, so that feature parity holds regardless of operating system.

#### Acceptance Criteria

1. THE Flutter_App SHALL provide the Auto Crop, Manual Crop, Rename Batch, and Tools features on both macOS and Windows.
2. THE Review_Canvas SHALL reach feature parity with the web canvas on both macOS and Windows before the feature is considered complete.
3. THE Flutter_App SHALL start, drive, and shut down the Sidecar on both macOS and Windows.
4. WHERE an operating-system-specific path is required for the Writable_Data_Dir, THE Flutter_App SHALL use the appropriate per-OS location.
