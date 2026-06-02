// Rename Batch form state (Requirements 12.1, 12.2).
//
// [RenameController] is a [ChangeNotifier] that holds the naming controls
// (pattern, start, padding, output format, JPG quality) and the list of loaded
// items. It contains NO engine logic: it only validates and clamps user input
// to the engine's accepted bounds and triggers a live preview via the
// [ApiClient] whenever a control changes.
//
// The controller computes the web UI's token expansion client-side (the
// `buildStem` / `planRenames` logic from `static/index.html`) and sends the
// resulting stems to `POST /api/rename/preview` so the engine can confirm the
// final names. This keeps the preview lightweight (no image bytes uploaded on
// every keystroke).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile, XTypeGroup;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/file_picker_service.dart';
import '../../models/rename.dart';

/// Engine-accepted bounds for the Rename Batch controls (Requirement 12.1).
class RenameBounds {
  const RenameBounds._();

  /// `start: int = Form(1, ge=0, le=1_000_000)`.
  static const int startMin = 0;
  static const int startMax = 1000000;
  static const int startDefault = 1;

  /// `padding: int = Form(0, ge=0, le=12)`.
  static const int paddingMin = 0;
  static const int paddingMax = 12;
  static const int paddingDefault = 0;

  /// `jpg_quality: int = Form(90, ge=1, le=100)`.
  static const int jpgQualityMin = 1;
  static const int jpgQualityMax = 100;
  static const int jpgQualityDefault = 90;

  /// Clamps [value] into the inclusive `[min, max]` range.
  static int clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

/// Output format options for the Rename Batch tool (Requirement 12.1).
enum RenameOutputFormat {
  original('original', 'Original'),
  png('png', 'PNG'),
  jpg('jpg', 'JPG'),
  jpeg('jpeg', 'JPEG'),
  webp('webp', 'WebP');

  const RenameOutputFormat(this.value, this.label);

  /// The exact `output_format` form value the engine expects.
  final String value;

  /// Human-readable label shown in the selector.
  final String label;
}

/// A single item in the rename batch (an image or a PDF page).
///
/// Carries the bytes that get streamed to the rename session's
/// `/files` endpoint (task 15.2): a picked image supplies [fileBytes]
/// directly, while a PDF page supplies its engine-rendered PNG inline as a
/// base64 [dataUrl]. [bytesForUpload] resolves whichever is present so the
/// session-upload step is source-agnostic.
class RenameItem {
  RenameItem({
    required this.name,
    this.width,
    this.height,
    this.sizeBytes = 0,
    this.fromPdf = false,
    this.dataUrl,
    this.fileBytes,
  });

  /// Builds a batch item from a [PdfImageItem] returned by
  /// `POST /api/rename/pdf-to-images`: the engine-rendered PNG arrives inline
  /// as a `data:` URL, which doubles as both the upload source and a preview.
  factory RenameItem.fromPdfImage(PdfImageItem image) {
    return RenameItem(
      name: image.name,
      width: image.width,
      height: image.height,
      sizeBytes: image.size,
      fromPdf: true,
      dataUrl: image.dataUrl,
    );
  }

  /// Original filename (e.g. "photo.jpg" or "doc_p01.png").
  final String name;

  /// Image dimensions (may be null until loaded).
  final int? width;
  final int? height;

  /// File size in bytes.
  final int sizeBytes;

  /// Whether this item came from a PDF-to-images conversion.
  final bool fromPdf;

  /// Data URL for preview (from PDF-to-images).
  final String? dataUrl;

  /// Raw file bytes for upload (from file picker / drag-drop).
  final List<int>? fileBytes;

  /// The bytes to stream to the rename session, preferring the raw
  /// [fileBytes] (picked image) and falling back to decoding the base64
  /// payload of a PDF page's [dataUrl]. Returns an empty list when neither is
  /// available (no engine logic — just transport plumbing).
  List<int> bytesForUpload() {
    final raw = fileBytes;
    if (raw != null) return raw;
    final url = dataUrl;
    if (url != null) {
      final comma = url.indexOf(',');
      if (url.startsWith('data:') && comma != -1) {
        try {
          return base64Decode(url.substring(comma + 1));
        } catch (_) {
          return const <int>[];
        }
      }
    }
    return const <int>[];
  }
}

/// Holds and validates the Rename Batch form state, triggers live preview,
/// and drives the PDF-to-images + streamed rename-&-download session flow.
///
/// On any control change, calls `POST /api/rename/preview` with the current
/// names, pattern, start, and padding to show a live before/after list
/// (Requirement 12.2). The preview is debounced to avoid flooding the engine
/// on rapid typing.
///
/// Adding files (Requirements 12.3, 17.2): [pickAndAddFiles] opens the native
/// images-and-PDF dialog; picked images become items directly, while a PDF is
/// converted to one renamable item per page via `POST /api/rename/pdf-to-images`
/// ([addPdfBytes]). The PDF rasterisation runs entirely in the engine — the
/// only Dart-side computation is the documented token expansion in [buildStem].
///
/// Renaming (Requirements 12.4, 12.5, 12.6): [rename] runs the streamed session
/// flow — `POST /api/rename/session` → chunked
/// `POST /api/rename/session/{id}/files` → `POST .../finalize` →
/// `GET .../download` (streamed to disk by the [DownloadService]) →
/// `DELETE /api/rename/session/{id}` — surfacing any engine `detail` on error.
///
/// There is ZERO engine logic in Dart beyond the token expansion: all
/// rasterising, re-encoding and packing happen in the Python engine, reached
/// over localhost HTTP.
class RenameController extends ChangeNotifier {
  /// Creates a controller. [apiClient] / [downloadService] are optional so the
  /// form can be exercised on its own (bounds/clamping + client-side preview)
  /// without a live engine; they are required for [addPdfBytes] / [rename] to
  /// issue requests, and are normally supplied via [bindEngine] once the
  /// sidecar reports ready. [filePickerService] backs [pickAndAddFiles].
  RenameController({
    ApiClient? apiClient,
    DownloadService? downloadService,
    FilePickerService filePickerService = const FilePickerService(),
  })  : _apiClient = apiClient,
        _downloadService = downloadService,
        _filePickerService = filePickerService;

  /// Files are uploaded to the session in groups of this many per request, so
  /// no single multipart body hits the engine's file-count cap or balloons
  /// memory (Requirement 12.4; the design specifies ~200/req).
  static const int renameUploadChunk = 200;

  /// The API client used to call the rename endpoints. When null (e.g. in
  /// tests or before the engine is ready), preview/PDF/rename calls are skipped.
  ApiClient? _apiClient;

  /// Streams the finalized ZIP to a user-chosen path. Bound alongside the
  /// [ApiClient]; when null, [rename] cannot save.
  DownloadService? _downloadService;

  /// Native open dialog for the Add Images affordance (Requirement 17.2).
  final FilePickerService _filePickerService;

  /// The bound API client, or null before the engine is ready.
  ApiClient? get apiClient => _apiClient;

  /// Whether the engine-backed services are bound (the sidecar is ready).
  bool get engineReady => _apiClient != null && _downloadService != null;

  /// Binds the engine-backed services once the sidecar reports ready (or
  /// re-binds with a fresh Base_URL across a restart). When [downloadService]
  /// is omitted a default one is built from [apiClient]. Refreshes the live
  /// preview if items are already loaded.
  void bindEngine({
    required ApiClient apiClient,
    DownloadService? downloadService,
  }) {
    _apiClient = apiClient;
    _downloadService = downloadService ?? DownloadService(apiClient);
    notifyListeners();
    if (_items.isNotEmpty) _schedulePreview();
  }

  /// Clears the engine-backed services (e.g. when the engine stops), so the
  /// rename/PDF affordances guard against an unavailable engine.
  void unbindEngine() {
    _apiClient = null;
    _downloadService = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  //  Naming controls (Requirement 12.1)
  // ---------------------------------------------------------------------------

  String _pattern = '#';
  int _start = RenameBounds.startDefault;
  int _padding = RenameBounds.paddingDefault;
  RenameOutputFormat _outputFormat = RenameOutputFormat.original;
  int _jpgQuality = RenameBounds.jpgQualityDefault;

  /// Naming pattern. `#` is replaced by the running number; variable tokens
  /// like `(name)`, `(width)`, etc. are expanded client-side.
  String get pattern => _pattern;
  set pattern(String value) {
    if (_pattern == value) return;
    _pattern = value;
    notifyListeners();
    _schedulePreview();
  }

  /// Start number (0–1,000,000).
  int get start => _start;
  set start(int value) {
    final next = RenameBounds.clamp(value, RenameBounds.startMin, RenameBounds.startMax);
    if (_start == next) return;
    _start = next;
    notifyListeners();
    _schedulePreview();
  }

  /// Zero-padding (0–12 digits).
  int get padding => _padding;
  set padding(int value) {
    final next = RenameBounds.clamp(value, RenameBounds.paddingMin, RenameBounds.paddingMax);
    if (_padding == next) return;
    _padding = next;
    notifyListeners();
    _schedulePreview();
  }

  /// Output format (original/png/jpg/jpeg/webp).
  RenameOutputFormat get outputFormat => _outputFormat;
  set outputFormat(RenameOutputFormat value) {
    if (_outputFormat == value) return;
    _outputFormat = value;
    notifyListeners();
    // Format doesn't affect the preview endpoint (it only changes extensions
    // client-side), but we still notify so the UI updates the preview names.
    _schedulePreview();
  }

  /// JPG quality (1–100). Only relevant when outputFormat is jpg/jpeg.
  int get jpgQuality => _jpgQuality;
  set jpgQuality(int value) {
    final next = RenameBounds.clamp(value, RenameBounds.jpgQualityMin, RenameBounds.jpgQualityMax);
    if (_jpgQuality == next) return;
    _jpgQuality = next;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  //  Items
  // ---------------------------------------------------------------------------

  final List<RenameItem> _items = <RenameItem>[];

  /// The current list of items in the batch.
  List<RenameItem> get items => List<RenameItem>.unmodifiable(_items);

  /// Number of items in the batch.
  int get itemCount => _items.length;

  /// Add items to the batch.
  void addItems(List<RenameItem> newItems) {
    _items.addAll(newItems);
    notifyListeners();
    _schedulePreview();
  }

  /// Remove an item at [index].
  void removeItem(int index) {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    notifyListeners();
    _schedulePreview();
  }

  /// Clear all items.
  void clearItems() {
    _items.clear();
    _previewItems = null;
    _previewError = null;
    notifyListeners();
  }

  /// Resets the whole tool back to its initial state: drops every loaded item
  /// and the preview, and restores the naming controls (pattern, start,
  /// padding, output format, JPG quality) plus any surfaced error / status to
  /// their defaults. The engine binding is preserved so the tool stays usable.
  /// A no-op while a session is in flight so a half-finished run isn't torn out
  /// from under the engine.
  void reset() {
    if (_busy) return;

    // Items + preview.
    _items.clear();
    _previewItems = null;
    _previewError = null;
    _previewLoading = false;
    _debounceTimer?.cancel();

    // Naming controls.
    _pattern = '#';
    _start = RenameBounds.startDefault;
    _padding = RenameBounds.paddingDefault;
    _outputFormat = RenameOutputFormat.original;
    _jpgQuality = RenameBounds.jpgQualityDefault;

    // Messages.
    _errorText = null;
    _statusText = null;

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  //  Live preview (Requirement 12.2)
  // ---------------------------------------------------------------------------

  List<RenamePlanItem>? _previewItems;
  String? _previewError;
  bool _previewLoading = false;
  Timer? _debounceTimer;

  /// The latest preview result (before/after pairs).
  List<RenamePlanItem>? get previewItems => _previewItems;

  /// Error message from the last preview call, if any.
  String? get previewError => _previewError;

  /// Whether a preview request is in flight.
  bool get previewLoading => _previewLoading;

  /// Debounce preview calls to avoid flooding the engine on rapid typing.
  void _schedulePreview() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _fetchPreview);
  }

  /// Calls `POST /api/rename/preview` with `names[]`, `pattern`, `start`, and
  /// `padding` and no image bytes (Requirement 12.2).
  ///
  /// The `names` sent are the **client-side expanded stems** (the web UI's
  /// `buildStem`/`planRenames` token expansion run in Dart): the engine's
  /// preview endpoint only understands the `#` number token, so the variable
  /// tokens (`(name)`, `(width)`, `(date)`, …) are expanded here and the
  /// resulting stems are shipped — exactly mirroring what the web UI computes
  /// client-side and what the session-finalize step (task 15.2) sends as the
  /// authoritative `names` array. No image bytes are uploaded.
  ///
  /// The displayed before/after list is driven by [previewPairs] (computed
  /// client-side for faithful parity with the web UI); this server round-trip
  /// is used to surface any engine error `detail` to the user (Requirement
  /// 12.6) and confirm reachability.
  Future<void> _fetchPreview() async {
    if (apiClient == null || _items.isEmpty) {
      _previewItems = null;
      _previewError = null;
      _previewLoading = false;
      notifyListeners();
      return;
    }

    _previewLoading = true;
    _previewError = null;
    notifyListeners();

    try {
      final response = await apiClient!.renamePreview(
        names: planStems(),
        pattern: _pattern.isEmpty ? '#' : _pattern,
        start: _start,
        padding: _padding,
      );
      _previewItems = response.items;
      _previewError = null;
    } on ApiException catch (e) {
      _previewError = e.detail;
      _previewItems = null;
    } catch (e) {
      _previewError = e.toString();
      _previewItems = null;
    } finally {
      _previewLoading = false;
      notifyListeners();
    }
  }

  /// Force a preview refresh (e.g. after adding items).
  void refreshPreview() {
    _schedulePreview();
  }

  // ---------------------------------------------------------------------------
  //  Add files: native picker + PDF-to-images (Requirements 12.3, 17.2)
  // ---------------------------------------------------------------------------

  bool _busy = false;
  String? _errorText;
  String? _statusText;

  /// Whether a long-running engine call (PDF conversion or rename session) is
  /// in flight. Drives the view's busy state and disables re-entrancy.
  bool get busy => _busy;

  /// The engine error `detail` (or a transport message) to surface above the
  /// form, or null when there is none (Requirement 12.6).
  String? get errorText => _errorText;

  /// A transient human-readable status line (e.g. "Uploading… 200 / 800"),
  /// or null when idle.
  String? get statusText => _statusText;

  /// Clears any surfaced error / status (e.g. before a fresh action).
  void clearMessages() {
    if (_errorText == null && _statusText == null) return;
    _errorText = null;
    _statusText = null;
    notifyListeners();
  }

  /// Opens the native images-and-PDF dialog (Requirement 17.2) and adds the
  /// selection: images become items directly, while each PDF is converted to
  /// one item per page via [addPdfBytes] (Requirement 12.3). A no-op when the
  /// user cancels. Engine errors during PDF conversion surface in [errorText].
  Future<void> pickAndAddFiles() async {
    final List<XFile> picked = await _filePickerService.pickImagesAndPdf();
    if (picked.isEmpty) return;
    await addXFiles(picked);
  }

  /// Opens a native folder picker and loads all image/PDF files from the
  /// selected directory. This is a workaround for macOS where CMD+A (select-all)
  /// does not work properly in the native file-open dialog. Users pick the
  /// folder and all matching files are loaded automatically.
  Future<void> pickAndAddFolder() async {
    final String? dirPath = await _filePickerService.pickFolder();
    if (dirPath == null) return;

    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    final List<XFile> files = <XFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (_isImageName(name) || _isPdfName(name)) {
        files.add(XFile(entity.path));
      }
    }

    if (files.isEmpty) return;
    // Sort by name for predictable ordering.
    files.sort((a, b) => a.name.compareTo(b.name));
    await addXFiles(files);
  }

  /// Adds already-selected files (from the native picker or a drop target) to
  /// the batch: images are loaded as items verbatim and PDFs are routed through
  /// [addPdfBytes]. Unsupported files are ignored. Reports an error if a PDF
  /// conversion fails (Requirement 12.6).
  Future<void> addXFiles(List<XFile> files) async {
    if (files.isEmpty) return;

    final List<RenameItem> images = <RenameItem>[];
    final List<XFile> pdfs = <XFile>[];
    for (final file in files) {
      final name = file.name;
      if (_isPdfName(name)) {
        pdfs.add(file);
      } else if (_isImageName(name)) {
        final bytes = await file.readAsBytes();
        images.add(RenameItem(
          name: name,
          sizeBytes: bytes.length,
          fileBytes: bytes,
        ));
      }
      // Anything else is silently skipped (mirrors the web UI's filtering).
    }

    if (images.isNotEmpty) addItems(images);

    for (final pdf in pdfs) {
      final bytes = await pdf.readAsBytes();
      final added = await addPdfBytes(bytes: bytes, filename: pdf.name);
      if (!added) return; // Stop on the first conversion error.
    }
  }

  /// Converts a PDF into renamable items via `POST /api/rename/pdf-to-images`
  /// and appends one item per page (Requirement 12.3). Each page arrives as an
  /// inline `data:` PNG that doubles as the upload source and a preview.
  ///
  /// Returns true on success; on an engine error the `{"detail": ...}` message
  /// is stored in [errorText] and false is returned (Requirement 12.6). A no-op
  /// (returns false) when no [ApiClient] is bound or a run is in flight.
  Future<bool> addPdfBytes({
    required List<int> bytes,
    required String filename,
  }) async {
    final client = _apiClient;
    if (client == null || _busy) return false;

    _busy = true;
    _errorText = null;
    _statusText = 'Converting $filename to images…';
    notifyListeners();

    try {
      final response = await client.renamePdfToImages(
        fileBytes: bytes,
        filename: filename,
      );
      final pages = response.images
          .map((image) => RenameItem.fromPdfImage(image))
          .toList();
      _busy = false;
      _statusText = null;
      // addItems notifies + schedules a preview refresh.
      addItems(pages);
      return true;
    } on ApiException catch (e) {
      _errorText = e.detail;
      _statusText = null;
      _busy = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorText = e.toString();
      _statusText = null;
      _busy = false;
      notifyListeners();
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  //  Rename: streamed session flow (Requirements 12.4, 12.5, 12.6)
  // ---------------------------------------------------------------------------

  /// Runs the streamed rename-&-download session flow and returns the
  /// [DownloadResult] (or null when it could not run / the user cancelled the
  /// Save-As dialog).
  ///
  /// The flow mirrors the web client for large batches (Requirement 12.4):
  ///   1. `POST /api/rename/session` → `session_id`
  ///   2. chunked `POST /api/rename/session/{id}/files`
  ///      (~[renameUploadChunk] files/req), keeping upload order aligned to the
  ///      planned stems
  ///   3. `POST /api/rename/session/{id}/finalize` with `pattern`, `start`,
  ///      `padding`, `names` (the client-expanded stems), `output_format`,
  ///      `jpg_quality`
  ///   4. `GET /api/rename/session/{id}/download` streamed to a user-chosen
  ///      path via the [DownloadService]
  ///   5. `DELETE /api/rename/session/{id}` to release the session
  ///      (Requirement 12.5), always attempted (best effort) once a session
  ///      exists.
  ///
  /// Any engine error surfaces its `detail` in [errorText] (Requirement 12.6).
  /// A no-op (returns null) when there are no items, a run is in flight, or the
  /// engine services are not bound.
  Future<DownloadResult?> rename() async {
    final client = _apiClient;
    final downloader = _downloadService;
    if (client == null || downloader == null || _busy || _items.isEmpty) {
      return null;
    }

    _busy = true;
    _errorText = null;
    _statusText = 'Preparing your batch…';
    notifyListeners();

    final List<String> stems = planStems();
    final List<RenameItem> batch = List<RenameItem>.of(_items);
    String? sessionId;
    try {
      // 1) Open a session.
      final session = await client.createRenameSession();
      sessionId = session.sessionId;

      // 2) Upload files in chunks, keeping stems aligned to upload order.
      var sent = 0;
      for (var i = 0; i < batch.length; i += renameUploadChunk) {
        final end = (i + renameUploadChunk < batch.length)
            ? i + renameUploadChunk
            : batch.length;
        final slice = batch.sublist(i, end);
        final files = <ApiUploadFile>[
          for (final item in slice)
            ApiUploadFile(
              bytes: item.bytesForUpload(),
              filename: item.name,
            ),
        ];
        await client.uploadRenameFiles(sessionId: sessionId, files: files);
        sent += slice.length;
        _statusText = 'Uploading… $sent / ${batch.length}';
        notifyListeners();
      }

      // 3) Finalize: the engine packs the ZIP from disk.
      _statusText = 'Renaming and packing your images…';
      notifyListeners();
      final finalize = await client.finalizeRenameSession(
        sessionId: sessionId,
        pattern: _pattern.isEmpty ? '#' : _pattern,
        start: _start,
        padding: _padding,
        names: stems,
        outputFormat: _outputFormat.value,
        jpgQuality: _jpgQuality,
      );

      // 4) Download — streamed from disk on the engine side, to a chosen path.
      final result = await downloader.download(
        engineUrl: finalize.downloadUrl,
        suggestedName: 'renamed_images.zip',
        acceptedTypeGroups: const <XTypeGroup>[_zipTypeGroup],
      );

      _statusText = result.isSaved
          ? 'Saved ${finalize.count} renamed '
              'image${finalize.count == 1 ? '' : 's'} as a ZIP.'
          : null;
      return result;
    } on ApiException catch (e) {
      _errorText = e.detail;
      _statusText = null;
      return null;
    } on DownloadException catch (e) {
      _errorText = e.message;
      _statusText = null;
      return null;
    } catch (e) {
      _errorText = e.toString();
      _statusText = null;
      return null;
    } finally {
      // 5) Best-effort cleanup of the staging dir (Requirement 12.5). The
      //    desktop download has already streamed to disk, so it is safe to
      //    drop the session immediately.
      if (sessionId != null) {
        try {
          await client.deleteRenameSession(sessionId);
        } catch (_) {
          // Cleanup is best-effort; never surface its failure to the user.
        }
      }
      _busy = false;
      notifyListeners();
    }
  }

  /// Save-As filter restricting the rename output to a `.zip` file.
  static const XTypeGroup _zipTypeGroup = XTypeGroup(
    label: 'ZIP archive',
    extensions: <String>['zip'],
    uniformTypeIdentifiers: <String>['public.zip-archive'],
    mimeTypes: <String>['application/zip'],
  );

  /// Whether [name] looks like a PDF (by extension).
  static bool _isPdfName(String name) => _splitExt(name) == 'pdf';

  /// Whether [name] looks like a supported image (by extension), reusing the
  /// picker's accepted image extensions.
  static bool _isImageName(String name) =>
      FilePickerService.imageExtensions.contains(_splitExt(name));

  // ---------------------------------------------------------------------------
  //  Token expansion (client-side, mirrors web UI's buildStem/planRenames)
  // ---------------------------------------------------------------------------

  /// Compute the output extension based on the current format setting.
  /// When format is "original", keeps the file's own extension.
  String outputExtension(String originalName) {
    switch (_outputFormat) {
      case RenameOutputFormat.jpg:
      case RenameOutputFormat.jpeg:
        return 'jpg';
      case RenameOutputFormat.png:
        return 'png';
      case RenameOutputFormat.webp:
        return 'webp';
      case RenameOutputFormat.original:
        final ext = p.extension(originalName);
        return ext.isNotEmpty ? ext.substring(1).toLowerCase() : '';
    }
  }

  /// Build the output stem for a single item at a given number, expanding
  /// all variable tokens client-side (mirrors the web UI's `buildStem`).
  String buildStem(RenameItem? item, int number) {
    final pad = _padding > 0 ? _padding : 0;
    String numStr = number.toString();
    if (pad > 0) {
      numStr = numStr.padLeft(pad, '0');
    }

    String base = _pattern.trim();
    if (base.isEmpty) base = '#';

    final name = item?.name ?? 'image.png';
    final stemName = _splitStem(name);
    final ext = _splitExt(name);
    final size = item?.sizeBytes ?? 0;

    String out = base;
    // Number tokens first.
    out = out.replaceAll('#', numStr);
    out = out.replaceAll(RegExp(r'\(n\)', caseSensitive: false), numStr);

    // Metadata tokens (case-insensitive).
    final Map<String, String> tokenMap = <String, String>{
      '(fullname)': name,
      '(name)': stemName,
      '(ext)': ext,
      '(width)': item?.width != null ? item!.width.toString() : '',
      '(height)': item?.height != null ? item!.height.toString() : '',
      '(date)': _formatDate(null),
      '(moddate)': _formatDate(null),
      '(size)': _humanSize(size).replaceAll(RegExp(r'\s+'), ''),
      '(sizekb)': (size / 1024).round().clamp(1, double.infinity).toInt().toString(),
      '(sizeb)': size.toString(),
    };

    for (final entry in tokenMap.entries) {
      out = out.replaceAll(
        RegExp(RegExp.escape(entry.key), caseSensitive: false),
        entry.value,
      );
    }

    // When the pattern has no number/variable token at all, append the
    // number so a constant pattern still yields unique names.
    final hadToken = RegExp(r'#|\([a-z]+\)', caseSensitive: false).hasMatch(base);
    if (!hadToken) out = '$out$numStr';

    // Sanitize filesystem-unsafe characters.
    out = out.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    if (out.isEmpty) out = numStr;
    return out;
  }

  /// Plan all renames: returns a list of final filenames (stem + extension),
  /// de-duplicating collisions. Mirrors the web UI's `planRenames` (the
  /// `names` half of its `{stems, names}` result).
  List<String> planRenames() => _plan().names;

  /// Plan the output **stems** (no extension), de-duplicating collisions.
  /// Mirrors the `stems` half of the web UI's `planRenames` — these are the
  /// authoritative names shipped to the engine (preview here, and the
  /// session-finalize `names` array in task 15.2).
  List<String> planStems() => _plan().stems;

  /// Client-side before/after pairs for the live preview, computed exactly
  /// like the web UI (no server round-trip needed to display them). The
  /// `before` is the item's original name; the `after` is the planned output
  /// filename (stem + extension).
  List<RenamePlanItem> get previewPairs {
    final plan = _plan();
    return <RenamePlanItem>[
      for (int i = 0; i < _items.length; i++)
        RenamePlanItem(original: _items[i].name, renamed: plan.names[i]),
    ];
  }

  /// Compute both stems and final names in one pass, de-duplicating
  /// collisions on each independently. Mirrors the web UI's `planRenames`,
  /// which returns `{ stems, names }`.
  _RenamePlan _plan() {
    final Map<String, int> usedStems = <String, int>{};
    final Map<String, int> usedNames = <String, int>{};
    final List<String> stems = <String>[];
    final List<String> names = <String>[];

    for (int idx = 0; idx < _items.length; idx++) {
      final item = _items[idx];
      String stem = buildStem(item, _start + idx);

      if (usedStems.containsKey(stem)) {
        usedStems[stem] = usedStems[stem]! + 1;
        stem = '${stem}_${usedStems[stem]}';
      } else {
        usedStems[stem] = 1;
      }
      stems.add(stem);

      final ext = outputExtension(item.name);
      String name = ext.isNotEmpty ? '$stem.$ext' : stem;

      if (usedNames.containsKey(name)) {
        usedNames[name] = usedNames[name]! + 1;
        name = ext.isNotEmpty
            ? '${stem}_${usedNames[name]}.$ext'
            : '${stem}_${usedNames[name]}';
      } else {
        usedNames[name] = 1;
      }

      names.add(name);
    }

    return _RenamePlan(stems: stems, names: names);
  }

  // ---------------------------------------------------------------------------
  //  Helpers
  // ---------------------------------------------------------------------------

  /// Extract the stem (filename without extension).
  static String _splitStem(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0) return filename;
    return filename.substring(0, dot);
  }

  /// Extract the extension (without the dot, lowercase).
  static String _splitExt(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return '';
    return filename.substring(dot + 1).toLowerCase();
  }

  /// Format a date as YYYY-MM-DD (mirrors the web UI's `fmtDate`).
  static String _formatDate(DateTime? date) {
    final d = date ?? DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Human-readable file size (mirrors the web UI's `humanSize`).
  static String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}

/// Internal result of [RenameController._plan]: the de-duplicated output stems
/// (shipped to the engine) and the matching final filenames (shown in the
/// preview). Mirrors the web UI's `planRenames` `{ stems, names }` shape.
class _RenamePlan {
  const _RenamePlan({required this.stems, required this.names});

  final List<String> stems;
  final List<String> names;
}
