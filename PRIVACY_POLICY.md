# Privacy Policy

**Qpic — MCQ Question Cropper**
*Last updated: June 4, 2026*

---

## Introduction

Qpic is a desktop application designed to detect, crop, and organize multiple-choice question (MCQ) regions from PDF examination papers. This Privacy Policy explains how Qpic handles your data, what information (if any) is collected, and how your privacy is protected.

**The core principle is simple: Qpic is a local-first application.** All PDF parsing, question detection, cropping, stitching, and image generation happen entirely on your machine. No data is sent anywhere unless you explicitly enable the optional Online AI mode and configure an API key yourself.

---

## Data We Collect

**Qpic does not collect any personal data.** Specifically:

- **No account required** — There is no sign-up, login, registration, or user profile of any kind.
- **No analytics or telemetry** — Qpic does not include any analytics frameworks, tracking pixels, usage monitoring, or telemetry systems.
- **No cookies** — Qpic does not use cookies or any browser-based tracking mechanisms.
- **No crash reporting** — Qpic does not automatically transmit crash reports or diagnostic data.
- **No network requests by default** — When running in offline mode (the default), Qpic makes zero network connections.
- **No usage statistics** — We do not track which features you use, how often you use the app, or how many documents you process.

---

## How Processing Works

Qpic uses a multi-tier detection pipeline to locate question regions in your PDF documents. Every tier listed below runs entirely on your local machine, with the sole exception of the optional Online AI tier (described separately):

### Tier 1 — Text Layer Detection
For searchable PDFs, Qpic reads the embedded text layer directly using PyMuPDF. This is instantaneous, requires no network access, and the text never leaves your device.

### Tier 2 — OCR Detection (Tesseract)
For scanned or image-based PDFs, Qpic uses Tesseract OCR to read page content. Tesseract is bundled with the desktop application and runs entirely offline. The OCR process includes deskewing, denoising, and adaptive thresholding — all performed locally. No page images or OCR results are transmitted anywhere.

### Tier 2.5 — Local ML Detection (YOLOv8 / ONNX)
Qpic includes an optional local machine learning tier that uses a YOLO-based object detection model (exported as ONNX) to identify question and answer regions. This model:

- Runs **100% offline** using the ONNX Runtime — no internet connection required.
- Detects question/solution regions using **bounding box coordinates only** — it identifies *where* questions are located on the page, not *what* they say.
- Does **not** read, extract, interpret, or understand the textual content of your documents.
- Processes page images that remain entirely in local memory and are never transmitted externally.

### Tier 3 — Online AI Detection (Optional)
See the dedicated section below.

### Cropping and Output
Once question regions are detected (by any tier), Qpic re-renders each region from the PDF vector source into crisp images. This cropping and stitching process is performed entirely by the Python engine on your local machine. The resulting images and ZIP archives are written to your local file system.

---

## Online AI Mode (Optional)

Qpic includes an **optional** Online AI tier that uses third-party vision models (Anthropic Claude or OpenRouter-compatible models) as a fallback for complex document layouts. This feature is **disabled by default** and is activated only when **both** of the following conditions are met:

1. You explicitly toggle **"Online mode (AI)"** to ON in the application interface.
2. You have manually configured a valid API key in the `.env` configuration file.

### What happens when Online AI is enabled

- **Page image thumbnails** of the PDF pages are sent to the configured AI provider (Anthropic or OpenRouter) over an encrypted HTTPS connection.
- The AI provider analyzes these images **solely** to return bounding box coordinates indicating where question regions are located on each page.
- The AI returns **positional data only** (coordinates and region boundaries) — not extracted document content.
- Only pages where the local detection tiers produced low-confidence results are sent to the AI provider, minimizing data exposure.

### What Qpic does NOT do with Online AI

- Qpic does **not** store, log, cache, or retain any data sent to or received from AI providers.
- Qpic does **not** send your documents to AI providers for content extraction, summarization, or any purpose other than question region detection.
- Qpic does **not** send metadata such as file names, file paths, your operating system details, or any identifying information to AI providers.
- Qpic does **not** maintain a persistent connection to any AI service — requests are made only during active document analysis when Online mode is on.

### How to stay fully offline

To ensure no data ever leaves your machine:
- Leave the **"Online mode (AI)"** toggle in the OFF position (the default), **or**
- Do not configure any API key in the `.env` file.

When no API key is configured, the Online mode toggle is automatically disabled in the interface and cannot be activated.

---

## Local ML Detection

The built-in machine learning model deserves specific mention because it involves AI technology that runs locally:

- The model is a **YOLOv8-based object detector** exported to ONNX format and executed via ONNX Runtime.
- It operates as a **visual region detector** — it identifies rectangular areas on a page image that are likely to contain questions, solutions, or descriptions.
- It outputs **bounding box coordinates and confidence scores only**. It does not perform optical character recognition, text extraction, natural language understanding, or content analysis.
- The model weights are bundled with the application and require no internet connection to function.
- All inference runs in local memory. No model inputs, outputs, or intermediate data are transmitted externally.
- Optional training data collection (when `LOCAL_ML_COLLECT_TRAINING_DATA` is enabled by the user) saves data exclusively to the user's local file system and never transmits it over the network.

---

## Data Storage

### Local file handling
All files processed by Qpic remain on your local file system at all times:

- **Input PDFs** are read from the location you specify and are never copied to external servers.
- **Output images and ZIP archives** are saved to your local file system — on macOS to `~/Library/Application Support/Qpic`, on Windows to `%LOCALAPPDATA%\Qpic`, or to a directory you choose via the Save dialog.
- **Job temporary files** (intermediate page renders, detection caches) are created in a local temporary directory and are **automatically cleaned up** after processing completes. A background cleanup timer ensures no stale temporary data persists.

### Configuration
Application settings (such as API keys, DPI preferences, and detection thresholds) are stored locally in the `.env` file within the application directory or in the operating system's standard preferences storage. These are never transmitted externally.

### No cloud storage
Qpic does not use any cloud storage, remote databases, or external file hosting services. There is no synchronization, backup, or replication of your data to any server.

---

## Third-Party Services

Qpic does not integrate with any third-party services by default. The only third-party services that may be contacted are the **optional** AI vision providers, and only when explicitly enabled by the user:

| Provider | When contacted | What is sent | What is received | Provider's privacy policy |
|---|---|---|---|---|
| **Anthropic** (Claude) | Only when Online mode is ON and an Anthropic API key is configured | Page image thumbnails via HTTPS | Bounding box coordinates for question regions | [anthropic.com/privacy](https://www.anthropic.com/privacy) |
| **OpenRouter** | Only when Online mode is ON and an OpenRouter API key is configured | Page image thumbnails via HTTPS | Bounding box coordinates for question regions | [openrouter.ai/privacy](https://openrouter.ai/privacy) |

When you choose to use these services, your interaction is also governed by the respective provider's privacy policy and terms of service. We recommend reviewing those policies before enabling Online mode.

**No other third-party services are used.** Qpic does not include:
- Advertising networks or ad tracking
- Social media integrations or share buttons
- Analytics platforms (Google Analytics, Mixpanel, etc.)
- Error reporting services (Sentry, Crashlytics, etc.)
- Content delivery networks for user data
- Any form of remote feature flags or A/B testing

---

## Children's Privacy

Qpic does not collect personal information from any user, regardless of age. Since the application does not require account creation, does not collect personal data, and does not communicate with external servers by default, there are no special concerns regarding children's use of the software.

Qpic is designed as a document processing tool and is suitable for use by students, educators, and anyone working with examination papers, without any age restrictions or privacy concerns.

---

## Security

While Qpic does not collect or transmit personal data, we take the following measures to protect your documents during processing:

- **Local processing** — Your documents are processed in memory on your local machine and are never written to external locations.
- **Temporary file cleanup** — Job-related temporary files are automatically deleted after processing, reducing the window during which intermediate data exists on disk.
- **Encrypted API communication** — When Online AI mode is used, all communication with AI providers occurs over HTTPS (TLS-encrypted connections).
- **No data retention** — Qpic does not maintain logs, databases, or caches of your document content between sessions.
- **API key security** — API keys are stored in your local `.env` file with appropriate file system permissions. They are never transmitted to any party other than the configured AI provider during authenticated API calls.

---

## Open Source Transparency

Qpic is released under the [MIT License](LICENSE). The complete source code is publicly available, allowing any user or security researcher to independently verify the privacy claims made in this policy. You can audit exactly what data the application accesses, processes, and (optionally) transmits.

---

## Changes to This Policy

We may update this Privacy Policy from time to time to reflect changes in the application's functionality or to clarify existing practices. When we do:

- The **"Last updated"** date at the top of this document will be revised.
- Significant changes (such as the introduction of new data processing capabilities or new third-party integrations) will be noted in the project's release notes and changelog.
- The updated policy will be included in the application's repository and distributed with new releases.

Since Qpic does not collect contact information, we cannot notify users directly of policy changes. We encourage you to review this policy periodically, particularly after updating to a new version.

---

## Contact

If you have questions, concerns, or suggestions regarding this Privacy Policy or Qpic's data handling practices, please reach out:

- **GitHub Issues** — Open an issue on the [Qpic repository](https://github.com/aniketmishra-0/ML_Qpic) for public inquiries.
- **Author** — Aniket Mishra

---

## Summary

| Aspect | Status |
|---|---|
| Personal data collection | **None** |
| Account / login required | **No** |
| Analytics / telemetry | **None** |
| Cookies / tracking | **None** |
| Default network access | **None** (fully offline) |
| Online AI mode | **Optional**, user-enabled only |
| Data sent to AI (when enabled) | Page image thumbnails only |
| AI response content | Bounding box coordinates only |
| Local ML model | **100% offline**, coordinates only |
| OCR processing | **100% local** (bundled Tesseract) |
| File storage | **Local file system only** |
| Cloud storage / sync | **None** |
| Temporary files | **Auto-cleaned** after processing |
| Source code | **Open source** (MIT License) |

---

*Copyright © 2026 Aniket Mishra. All rights reserved.*
