# Qpic — How to Use

> **Qpic** is a desktop application for macOS and Windows that automatically
> detects and crops MCQ questions from PDF exam papers. It uses a smart
> multi-tier detection pipeline (text analysis, OCR, local ML, and optional AI
> vision), lets you review and fix every detection on an interactive canvas, and
> exports crisp, high-resolution cropped images — all from one double-click.

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Auto Crop (Main Feature)](#auto-crop-main-feature)
3. [Manual Crop](#manual-crop)
4. [ML Detection — How It Works](#ml-detection--how-it-works)
5. [Bilingual PDF Support](#bilingual-pdf-support)
6. [Rename Batch](#rename-batch)
7. [Tools](#tools)
8. [Output Options](#output-options)
9. [Answer Sheet (Auto-Generated)](#answer-sheet-auto-generated)
10. [Keyboard Shortcuts](#keyboard-shortcuts)
11. [Privacy](#privacy)
12. [Troubleshooting](#troubleshooting)

---

## Getting Started

### Launching the App

- **Double-click** the Qpic application icon — no terminal, no command line, no
  server to start manually.
- On **macOS**, open `Qpic.app` from your Applications folder (or wherever you
  placed it). If you see an "unidentified developer" warning on an unsigned
  build, right-click the app and choose **Open** to allow it.
- On **Windows**, run the installed Qpic application from the Start Menu or
  desktop shortcut.

### What Happens at Launch

1. Qpic starts a local **processing engine** (the "sidecar") automatically in
   the background. This engine handles all PDF parsing, detection, and cropping.
2. A startup screen shows a brief loading indicator while the engine initializes.
   This typically takes a few seconds on first launch.
3. Once the engine is ready, the main interface appears with the **Auto Crop**
   tab active and ready to accept a PDF.

> **Tip:** The engine runs entirely on your machine. No internet connection is
> required for standard operation — AI features are optional and off by default.

### Interface Overview

The app is organized into tabs along the top:

| Tab | Purpose |
|---|---|
| **Auto Crop** | Detect and crop questions automatically |
| **Manual Crop** | Draw every crop box by hand |
| **Rename Batch** | Bulk rename image files |
| **Tools** | Compress, Edit, and Preflight PDFs |

A **theme switcher** (light / dark / system) sits in the top-right corner. Qpic
follows your OS preference by default; override it anytime.

---

## Auto Crop (Main Feature)

Auto Crop is the primary workflow. It detects questions in your PDF, lets you
review the results, and exports clean cropped images.

### Step 1 — Load a PDF

- Click **"Choose PDF"** in the upload area, **or**
- **Drag and drop** a PDF file directly onto the upload area.
- Supported: any MCQ question paper PDF — searchable, scanned, or image-based.

### Step 2 — Configure Options

Before analyzing, set up how Qpic should process your document. Options are
organized into a **"What to Crop"** panel on the left:

#### Question Numbering

Controls which numbering style is treated as a real question start (so option
labels, sub-parts, and equation numbers are not mistaken for questions):

| Style | When to Use |
|---|---|
| **auto** (default) | Works for most papers. Prefers explicit Q markers; falls back to bare numbers. |
| **q** | Questions labelled `Q1`, `Q.1`, `Question 1`, etc. |
| **numbered** | Bare leading numbers only: `1.`, `2)`, `3.`, etc. |

#### Smart Mode

- **ON** (default) — Runs the full detection pipeline and opens the **Review
  Canvas** so you can verify and fix every detection before downloading.
- **OFF** — Skips the review step and goes straight to a ZIP download.

> **Recommendation:** Keep Smart mode ON. It catches edge cases that a
> fully-automatic pass might miss, and the review step only takes a moment.

#### Online Mode (AI)

- **ON** — Enables the AI vision fallback for tricky or unusual layouts. The
  cheaper text/OCR tiers still run first; AI is only called when they struggle.
  Requires an API key configured in the app settings.
- **OFF** (default) — Fully offline. Only text analysis and OCR are used. No
  network calls are made.

The toggle auto-disables itself when no AI key is configured.

**Configuring an AI key:** Go to the app settings and enter your API key. Two
providers are supported:

- **OpenRouter** — OpenAI-compatible endpoint supporting Gemini, Qwen, Llama,
  and free models.
- **Anthropic** — Direct Anthropic API with Claude models.

#### Page Ranges

- By default, the entire PDF is processed.
- Enter specific page ranges (e.g., `1-5`, `8, 12-15`) to process only certain
  pages — useful for large documents or when you only need a specific section.

#### What to Crop

Toggle which content types to include:

- **Questions** — the question stems and their options.
- **Solutions** — answer explanations or worked solutions, if present.

#### Answer Sheet

- **ON** (default) — When the PDF contains an answer key (e.g., `1-B 2-A 3-D`),
  Qpic bundles an `answers.csv` and `answers.json` mapping each cropped question
  to its correct option.
- **OFF** — Skips answer-sheet generation.

### Step 3 — Analyze

Click **"Analyze"** (or **"Analyze & Review"** in Smart mode). Qpic runs its
detection pipeline:

```
Text Layer → Tesseract OCR → Local ML (YOLO) → optional Online AI
```

Each tier runs only if needed. For a searchable PDF with clear numbering, text
analysis alone is often sufficient. Scanned or image-based PDFs escalate to OCR
and, if enabled, the AI fallback.

A progress indicator shows which tier is running and how many pages have been
processed.

### Step 4 — Review Canvas

After analysis, the **Review Canvas** opens. This is where you verify and
correct every detection before downloading.

#### Reading the Canvas

- **Green boxes** = Detected questions. Hover over a box to see its assigned
  question number.
- **Orange flagged boxes** = Suspicious detections — crops that look cut off,
  unusually short, or may be missing options. These are worth checking.
- **Review Notes** appear in a panel on the right, listing every flagged issue
  with an explanation.

#### Fixing Detections

| Action | How |
|---|---|
| **Fix a bad box** | Click the **Fix** (or **Re-select**) button on its review note, then drag the correct region on the page preview. |
| **Draw a missing question** | Click the **Draw** button, then drag a box around the missed question on the page. |
| **Delete a duplicate** | Click the box to select it, then click **Delete**. |
| **Move or resize a box** | Click and drag the box edges or corners to adjust. |

#### Snap to Content

- **ON by default.** When you draw or adjust a box, Qpic automatically tightens
  it to hug the actual text and figures inside — a rough drag becomes a clean,
  precise crop.
- This uses content-aware analysis to find the optimal tight boundary.

#### Smart Review Features

The review canvas includes several intelligent checks:

- **Gap Recovery** — If detected numbering skips a value (e.g., 19 jumps to 21),
  Qpic re-reads the gap region with OCR digit-confusion fixups and re-inserts
  the missed question.
- **Answer-Key Cross-Check** — If the paper has an answer key, Qpic knows
  exactly how many questions should exist and flags any that were not detected.
- **Option Check** — Standard MCQs have options (A)–(D). A crop capturing only
  some options (e.g., just the left column of a 2-column option grid) is flagged
  so you can re-select it.
- **Cut-Off Detection** — Crops that stop at a page edge or are much shorter
  than their neighbours are flagged as likely truncated.

### Step 5 — Finalize & Download

Once you are satisfied with the review:

1. Click **"Finalize & Download"**.
2. Choose your download type:

| Download Type | Contents |
|---|---|
| **Combined** | Questions + Solutions in one ZIP (`QScombined.zip`) |
| **Questions Only** | Questions ZIP (`Q.zip`) |
| **Solutions Only** | Solutions ZIP (`S.zip`) |

Images are re-rendered crisp from the original PDF vector source at your
configured DPI — not upscaled from previews — so text stays sharp at any zoom.

---

## Manual Crop

For when you want full control and prefer to draw every box by hand.

### Workflow

1. Switch to the **Manual Crop** tab.
2. **Load a PDF** — same as Auto Crop (click "Choose PDF" or drag-and-drop).
3. Page previews appear in the canvas.
4. **Draw boxes** around each question or region you want to crop.
   - Click and drag to create a rectangular selection.
   - Snap to Content (if enabled) auto-tightens each drawn box.
5. **Finalize & Download** — exports your hand-drawn regions as cropped images
   in a ZIP.

Manual Crop is useful for non-standard layouts, artistic documents, or any
situation where automatic detection does not apply.

---

## ML Detection — How It Works

Qpic uses a multi-tier detection pipeline. Understanding what each tier does
helps you get the best results.

### Detection Tiers

| Tier | Method | When Used |
|---|---|---|
| **1. Text Layer** | Reads the PDF's embedded text directly | Searchable PDFs with a proper text layer |
| **2. OCR (Tesseract)** | Optical Character Recognition on page images | Scanned PDFs or when the text layer is missing |
| **2.5 Local ML (YOLOv8/ONNX)** | Offline neural network model | After OCR, before any online AI call |
| **3. AI Vision** | Cloud-based vision model (optional) | Hard layouts where local methods struggle |

### What the ML Model Does — and Does Not Do

> **Important:** The ML model detects question and solution **regions**
> (bounding boxes) only. It finds *where* questions are on the page.

- It does **NOT** read, understand, or interpret your document content.
- It does **NOT** extract or store text from your papers.
- It identifies layout regions: `Question_Block`, `Question_Answer_Block`,
  `Description`, etc.

### About Online AI (When Enabled)

- When Online AI mode is turned on (optional), only **page images** are sent to
  the AI provider to get **coordinate positions** back.
- The AI returns bounding box coordinates — it tells Qpic *where* questions are.
- All **actual cropping** happens locally from the original PDF file on your
  machine.
- Only low-confidence pages are sent to AI (not the whole document), minimizing
  data exposure and cost.

### OCR Quality

Qpic bundles high-accuracy Tesseract models (`tessdata_best` LSTM) for English.
For scanned PDFs, the OCR tier:

- **Deskews** tilted pages automatically.
- **Denoises** speckle and artifacts.
- Uses **adaptive (Otsu) thresholding** for clean text extraction.
- Records **per-page confidence** scores. In Smart mode, only weak pages are
  escalated to the AI tier.

---

## Bilingual PDF Support

Qpic automatically handles side-by-side bilingual exam papers (e.g., English on
the left column, a second language on the right).

### How It Works

1. **Automatic Detection** — During analysis, Qpic detects bilingual
   side-by-side layouts and flags them.
2. **Duplicate Merging** — When the same question appears in both languages,
   Qpic merges the duplicate detections into paired items rather than listing
   each language version separately.
3. **Bilingual Mode** — When a bilingual layout is detected, the Bilingual Mode
   toggle activates automatically.

### Bilingual Stitcher Modes

When finalizing a bilingual PDF, you can choose how the two language versions
are exported:

| Mode | Output |
|---|---|
| **English Only** | Crops only the English (primary) column |
| **Second Language Only** | Crops only the translation column |
| **Horizontal** | Stitches both columns side-by-side in a single wide image |
| **Vertical** | Stacks the English column above the translation column in a single tall image |

### Math-Only Solutions

Solutions that contain only mathematical content (equations, diagrams) without
any translated text are automatically expanded to full page width, since
splitting them into language columns would be meaningless.

---

## Rename Batch

Bulk rename a set of already-cropped image files with a consistent naming
scheme.

### Workflow

1. Switch to the **Rename Batch** tab in the top bar.
2. **Upload images** — drag-and-drop or select multiple image files (PNG, JPEG,
   etc.).
3. **Set a naming pattern:**
   - **Prefix** — e.g., `Q`, `Question`, `MCQ`.
   - **Start number** — the number the sequence begins at (e.g., 1, 101).
   - **Variables** — use the Variables button to insert dynamic tokens like `{n}`
     for auto-numbering.
4. **Preview** — the gallery shows the new filenames before you commit.
5. **Remove** any unwanted files from the batch.
6. Click **"Rename & Download ZIP"** to download the renamed files.

---

## Tools

The **Tools** tab provides three standalone PDF utilities. These work
independently of the cropping feature.

### Compress PDF

Shrink a PDF file by recompressing images, subsetting fonts, and cleaning object
streams.

| Compression Level | Description |
|---|---|
| **Light** | Minimal quality loss, modest size reduction |
| **Balanced** | Good balance of quality and file size |
| **Strong** | Aggressive compression, noticeable quality reduction |
| **Extreme** | Maximum compression for smallest file size |

You can also set a **target size in MB** and Qpic will push quality down until
the file fits (best-effort, never below readable quality). The result reports
before/after size and the percentage saved.

### Edit PDF

Edit text directly in a PDF while preserving the original formatting.

- Each text run appears as a clickable box over the page preview.
- Changes are re-inserted using the document's **own embedded font**, at the
  same size and colour, fitted to the original bounding box.
- A **Run OCR** button can convert a scanned/image PDF into a searchable one
  (invisible Tesseract text layer), making its text editable.

### Preflight PDF

A read-only pre-press quality check that reports:

- Page count and sizes
- Embedded vs. non-embedded fonts
- Image resolution (low-DPI images flagged as blurry in print)
- RGB vs. CMYK colour spaces
- Encryption status
- Searchable-text check

Results are rolled up into a single **PASS / WARN / FAIL** verdict with
actionable messages.

---

## Output Options

Configure how cropped images are exported. These settings are in the **"Output
Options"** panel on the right side of the Auto Crop view.

| Option | Values | Default | Description |
|---|---|---|---|
| **DPI** | 72–600 | 400 | Resolution of cropped images. Higher = crisper but larger files. |
| **Padding** | 0–100 px | 20 px | Extra whitespace around each crop boundary. |
| **Image Format** | PNG / JPEG | PNG | PNG for lossless quality; JPEG for smaller files. |
| **Question Prefix** | Any text | `Q` | Filename prefix for question images (e.g., `Q001.png`). |
| **Solution Prefix** | Any text | `S` | Filename prefix for solution images (e.g., `S001.png`). |
| **Start Number** | Any integer | 1 | First number in the filename sequence. |

---

## Answer Sheet (Auto-Generated)

When a PDF contains an answer key (e.g., `1-B  2-A  3-D  4-C ...`), Qpic
automatically generates companion files in the download:

- **`answers.csv`** — Opens directly in Excel or Google Sheets. Columns:
  `file`, `question`, `answer` (e.g., `Q001.png, 1, B`).
- **`answers.json`** — Machine-readable format for importing into quiz apps,
  Anki pipelines, or custom tools.

The answer sheet is included in the **Questions** and **Combined** ZIPs (not the
Solutions-only ZIP, since it is keyed to question images).

**How the key is read:**
- From a **searchable PDF**, the text layer is parsed directly (free, instant).
- From a **scanned PDF** with an empty text layer, the AI vision tier reads the
  key from page images — only when Online mode is on and an AI key is configured.
- If no answer key is found in the document, no sheet is generated.

Toggle this feature with the **Answer sheet** switch in Output Options.

---

## Keyboard Shortcuts

### General

| Shortcut | macOS | Windows | Action |
|---|---|---|---|
| Open File | `Cmd + O` | `Ctrl + O` | Open a PDF file |
| Quit | `Cmd + Q` | `Ctrl + Q` | Quit Qpic |

### Edit (Text Fields)

| Shortcut | macOS | Windows | Action |
|---|---|---|---|
| Cut | `Cmd + X` | `Ctrl + X` | Cut selected text |
| Copy | `Cmd + C` | `Ctrl + C` | Copy selected text |
| Paste | `Cmd + V` | `Ctrl + V` | Paste text |
| Select All | `Cmd + A` | `Ctrl + A` | Select all text |

### View / Zoom

| Shortcut | macOS | Windows | Action |
|---|---|---|---|
| Zoom In | `Cmd + =` | `Ctrl + =` | Zoom in on the canvas / document view |
| Zoom Out | `Cmd + -` | `Ctrl + -` | Zoom out on the canvas / document view |
| Reset Zoom | `Cmd + 0` | `Ctrl + 0` | Reset to fit-width / actual size |
| Scroll to Zoom | Scroll wheel | Scroll wheel | Zoom in/out on the review canvas |

### Review Canvas

| Shortcut | Action |
|---|---|
| `Space` (hold) | Pan mode — click and drag to pan the canvas |
| `Shift` (hold) | Constrain mode for drawing or resizing |
| `Escape` | Cancel current drawing or deselect |
| `Delete` / `Backspace` | Delete selected box |

---

## Privacy

Qpic is designed with your privacy as a priority.

- **100% Local Execution** — All PDF extraction, cropping, and image processing
  happens on your machine. No remote servers are involved in standard operation.
- **Zero Telemetry** — Qpic does not collect, store, or transmit any of your
  data. There are no tracking scripts or analytics.
- **Offline ML** — The built-in YOLOv8 layout detection model is fully
  self-contained and runs entirely offline.
- **Secure File Handling** — Your documents and exported images remain within
  your local file system, protected under standard system permissions.
- **Optional AI is transparent** — When you choose to enable Online mode, only
  page images are sent to the configured AI provider to receive bounding-box
  coordinates back. The actual document content is never uploaded. This is
  entirely opt-in.

---

## Troubleshooting

### "Engine not responding"

The local processing engine (sidecar) starts automatically when you launch Qpic.
If you see this message:

1. **Wait a few seconds.** The engine may still be initializing, especially on
   first launch or after an OS restart.
2. If the message persists, **quit and relaunch** the app.
3. Check that no other application is occupying port 8000 on your machine.

### "No questions detected"

The detection pipeline did not find any question regions. Try the following:

1. **Change the question numbering style.** If your paper uses `Q1, Q2...`
   format, switch from `auto` to `q`. If it uses `1. 2. 3.` format, try
   `numbered`.
2. **Enable Online mode (AI).** Some unusual layouts (multi-column, decorative
   borders, non-standard numbering) are better handled by the AI vision tier.
3. **Check page ranges.** Make sure you are processing the pages that contain
   questions.
4. **Check the PDF itself.** A corrupted or password-protected PDF may not be
   readable.

### Poor OCR / Cropped Questions Cut Off

- Qpic bundles high-accuracy Tesseract models (`tessdata_best` LSTM). If you
  still get poor OCR on scanned papers:
  - The scan quality matters. Very low-resolution scans (below 150 DPI) produce
    weaker OCR results.
  - Badly skewed scans are auto-corrected, but extreme tilt may still cause
    issues.
  - Try enabling **Online mode** — the AI tier can compensate for weak OCR pages.

### Images Are Too Large / Too Small

- Adjust the **DPI** setting in Output Options:
  - **72 DPI** — screen-resolution, small files.
  - **200 DPI** — good balance for on-screen use.
  - **400 DPI** (default) — high quality, sharp text at any zoom.
  - **600 DPI** — maximum quality for print.

### Cropped Images Have Too Much / Too Little Whitespace

- Adjust the **Padding** value in Output Options (default: 20 px).
- Use the **Snap to Content** feature when drawing or fixing boxes — it
  auto-tightens crops to the actual content boundary.

### App Shows a Blank Window

- Ensure your OS is up to date (macOS 11+ or Windows 10+).
- Try toggling the theme (light/dark) from the top-right corner.
- Quit and relaunch the app.

### Files Are Saved Where?

Cropped images and ZIP files are saved to:

- **macOS:** `~/Library/Application Support/Qpic`
- **Windows:** `%LOCALAPPDATA%\Qpic`

When you click "Finalize & Download", a native Save dialog lets you choose where
to save the final ZIP.

---

## Getting Help

- **In-app Help:** Open **Help → How to Use Qpic** from the menu bar for a
  quick walkthrough.
- **About:** Open **Qpic → About Qpic** from the menu bar for version info.

---

*Qpic is released under the [MIT License](LICENSE) — © 2026 Aniket Mishra.*
