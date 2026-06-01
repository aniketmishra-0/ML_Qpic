// Edit tool state: open + clickable spans (Req 15.1-15.3, 15.8) plus in-place
// editing, apply, OCR, and download (Req 15.4, 15.5, 15.6, 15.7).
//
// [EditController] is a [ChangeNotifier] that drives the whole Edit-tool flow:
//
//   * [open] uploads a PDF via `POST /api/tools/edit/open` (through [ApiClient],
//     which mirrors the engine endpoint verbatim) and stores the returned
//     [EditExtractResponse] — the per-page geometry/previews and the editable
//     spans (Req 15.1). [pages] / [spansForPage] / [previewUri] expose what the
//     view needs to render each page from its server-rendered `preview_url` and
//     overlay each span as a clickable box (Req 15.2, 15.3).
//   * Clicking a span selects it ([selectSpan]); the view then shows an in-place
//     text field whose committed value is recorded by [setSpanText] (Req 15.4).
//   * [apply] turns the pending edits into `edit_text` operations and calls
//     `POST /api/tools/edit/apply` (Req 15.5).
//   * [runOcr] re-submits the opened PDF to `POST /api/tools/edit/ocr` with the
//     chosen languages + DPI, then reopens the searchable result as the new
//     editable source (Req 15.6).
//   * [download] streams the edited / OCR'd PDF to disk via the
//     [DownloadService] from `GET /api/tools/edit/download/{job_id}` (Req 15.7).
//   * [hasText] reflects the engine's `has_text`; when false the view shows the
//     "add objects or run OCR to edit existing text" guidance (Req 15.8).
//
// There is NO engine logic here: span extraction, font matching, OCR, and PDF
// rendering all run in the Python engine and are reached over localhost HTTP.
// The controller only marshals inputs, records the user's text overrides, and
// surfaces engine errors verbatim.

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/foundation.dart';

import '../../../core/api_client.dart';
import '../../../core/download_service.dart';
import '../../../models/tools.dart';

/// Lifecycle of the Edit tool's open flow.
enum EditStatus {
  /// No document opened yet — the view shows the drop/open prompt.
  idle,

  /// An `edit/open` request is in flight.
  opening,

  /// A document is staged: [EditController.response] is populated.
  ready,

  /// The last open attempt failed; [EditController.errorDetail] explains why.
  error,
}

/// Engine-accepted bounds for the OCR controls (`edit_ocr` `dpi=Form(ge=150,
/// le=600)` in `app/routers/tools.py`).
class EditOcrBounds {
  const EditOcrBounds._();

  /// Lowest rasterization DPI the engine accepts for OCR.
  static const int dpiMin = 150;

  /// Highest rasterization DPI the engine accepts for OCR.
  static const int dpiMax = 600;

  /// The engine's default OCR DPI (the `edit_ocr` form default).
  static const int dpiDefault = 300;
}

/// Holds the staged Edit document, the user's pending text edits, and the
/// apply / OCR / download action state.
class EditController extends ChangeNotifier {
  /// Creates a controller bound to [api]. [downloadService] is optional so
  /// tests can construct the controller without the native Save-As channel; in
  /// the app a real [DownloadService] (sharing [api]'s Dio + Base_URL) is used
  /// to stream the edited / OCR'd PDF to disk.
  EditController({required ApiClient api, DownloadService? downloadService})
      : _api = api,
        _downloadService = downloadService ?? DownloadService(api);

  final ApiClient _api;
  final DownloadService _downloadService;

  // --- Open flow ------------------------------------------------------------

  EditStatus _status = EditStatus.idle;
  EditExtractResponse? _response;
  List<int>? _fileBytes;
  String? _fileName;
  String? _errorDetail;
  String? _selectedSpanId;

  // --- Edits / actions ------------------------------------------------------

  /// span id → replacement text. Only spans whose text actually changed are
  /// kept here (mirrors the web editor's `state.edits` map).
  final Map<String, String> _edits = <String, String>{};

  String _ocrLanguages = '';
  String _ocrDpiText = '${EditOcrBounds.dpiDefault}';

  bool _applying = false;
  bool _ocrRunning = false;
  EditApplyResponse? _applyResult;
  OcrResponse? _ocrResult;

  /// The job whose edited / OCR'd PDF can be downloaded, or null when nothing
  /// has been produced yet. Set after a successful [apply] or [runOcr].
  String? _downloadJobId;

  /// An apply / OCR / download error to surface in the ready view, kept apart
  /// from the open-flow [errorDetail] so a transient action error doesn't tear
  /// down the staged document.
  String? _actionError;

  // --- Open-flow getters (task 18.1) ---------------------------------------

  /// Current open-flow status.
  EditStatus get status => _status;

  /// The staged document's spans + page geometry, or null before a successful
  /// open. Set only on a 2xx `edit/open` (or post-OCR `edit/{job}/state`).
  EditExtractResponse? get response => _response;

  /// Name of the opened PDF, shown in the header. Null until a file is opened.
  String? get fileName => _fileName;

  /// The engine's error `detail` from the last failed open, surfaced verbatim.
  /// Null unless [status] is [EditStatus.error].
  String? get errorDetail => _errorDetail;

  /// Id of the span the user last clicked, or null. The view renders an
  /// in-place text field for the selected span (Req 15.4).
  String? get selectedSpanId => _selectedSpanId;

  /// Whether a document is currently staged.
  bool get hasDocument => _response != null;

  /// The engine's `has_text` for the staged document. False for a scanned PDF
  /// with no selectable text; the view then shows the OCR guidance (Req 15.8).
  bool get hasText => _response?.hasText ?? false;

  /// The staged document's pages (geometry + `preview_url`), or an empty list.
  List<EditPageModel> get pages => _response?.pages ?? const <EditPageModel>[];

  /// All editable spans for the staged document, or an empty list.
  List<EditableSpanModel> get spans =>
      _response?.spans ?? const <EditableSpanModel>[];

  /// The editable spans on [pageNumber] (the engine's 1-indexed page number).
  List<EditableSpanModel> spansForPage(int pageNumber) {
    return spans.where((s) => s.page == pageNumber).toList(growable: false);
  }

  /// Resolves a page's server-rendered preview into an absolute URL on the
  /// engine Base_URL, for `Image.network` (Req 15.2). The bytes are a
  /// server-produced PNG — no PDF rasterization happens in Dart (Req 1.5).
  Uri previewUri(EditPageModel page) => _api.resolveUri(page.previewUrl);

  // --- Edit getters ---------------------------------------------------------

  /// The text to show for [span]: the user's override when present, otherwise
  /// the engine's original text (mirrors the web `state.edits[id] ?? span.text`).
  String effectiveText(EditableSpanModel span) =>
      _edits[span.id] ?? span.text;

  /// Whether [spanId] has a pending (uncommitted-to-engine) text override.
  bool isSpanEdited(String spanId) => _edits.containsKey(spanId);

  /// Number of spans with a pending text change (drives the "N changes" chip).
  int get pendingEditCount => _edits.length;

  /// Whether there is at least one pending text change to apply.
  bool get hasPendingEdits => _edits.isNotEmpty;

  // --- OCR control getters --------------------------------------------------

  /// The Tesseract language spec to send to OCR (e.g. `eng` or `eng+hin`).
  /// Empty means "use the engine's configured default" (the `edit_ocr` default).
  String get ocrLanguages => _ocrLanguages;
  set ocrLanguages(String value) {
    if (_ocrLanguages == value) return;
    _ocrLanguages = value;
    notifyListeners();
  }

  /// The raw OCR-DPI text exactly as entered, so the field preserves keystrokes.
  String get ocrDpiText => _ocrDpiText;
  set ocrDpiText(String value) {
    if (_ocrDpiText == value) return;
    _ocrDpiText = value;
    notifyListeners();
  }

  /// The parsed OCR DPI, or null when the field isn't a whole number.
  int? get ocrDpi => int.tryParse(_ocrDpiText.trim());

  /// Whether the OCR DPI entry is within the engine's accepted 150–600 range.
  bool get isOcrDpiValid {
    final value = ocrDpi;
    return value != null &&
        value >= EditOcrBounds.dpiMin &&
        value <= EditOcrBounds.dpiMax;
  }

  // --- Action-state getters -------------------------------------------------

  /// Whether an apply request is in flight.
  bool get applying => _applying;

  /// Whether an OCR request (or its post-OCR reopen) is in flight.
  bool get ocrRunning => _ocrRunning;

  /// Whether any edit action is in flight (apply or OCR).
  bool get busy => _applying || _ocrRunning;

  /// The most recent successful apply result, or null.
  EditApplyResponse? get applyResult => _applyResult;

  /// The most recent successful OCR result, or null.
  OcrResponse? get ocrResult => _ocrResult;

  /// An apply / OCR / download error to display in the ready view, or null.
  String? get actionError => _actionError;

  /// Whether [apply] can run: the doc has text, there are pending edits, and no
  /// action is in flight.
  bool get canApply => hasText && hasPendingEdits && !busy;

  /// Whether OCR can run: a document is staged and no action is in flight.
  bool get canRunOcr => _fileBytes != null && !busy && isOcrDpiValid;

  /// Whether an edited / OCR'd PDF is available to download (Req 15.7).
  bool get canDownload => _downloadJobId != null && !busy;

  // --- Open -----------------------------------------------------------------

  /// Opens [fileBytes] (a PDF named [filename]) for editing.
  ///
  /// Calls `POST /api/tools/edit/open`; on success stores the response and
  /// transitions to [EditStatus.ready], on an engine error stores the `detail`
  /// and transitions to [EditStatus.error]. Returns true on success.
  Future<bool> open({
    required List<int> fileBytes,
    required String filename,
  }) async {
    _status = EditStatus.opening;
    _fileBytes = fileBytes;
    _fileName = filename;
    _errorDetail = null;
    _resetEditState();
    notifyListeners();

    try {
      final EditExtractResponse res = await _api.editOpen(
        fileBytes: fileBytes,
        filename: filename,
      );
      _response = res;
      _status = EditStatus.ready;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _response = null;
      _errorDetail = e.detail;
      _status = EditStatus.error;
      notifyListeners();
      return false;
    }
  }

  /// Selects the span [spanId] (the box the user clicked) so the view can show
  /// an in-place editor for it. Pass null to clear the selection.
  void selectSpan(String? spanId) {
    if (_selectedSpanId == spanId) return;
    _selectedSpanId = spanId;
    notifyListeners();
  }

  // --- In-place text editing (Req 15.4) -------------------------------------

  /// Records the user's committed text for [spanId].
  ///
  /// When [newText] equals the span's original text the override is dropped (so
  /// re-typing the original "un-edits" the span); otherwise it is stored as a
  /// pending edit. A no-op when nothing actually changes.
  void setSpanText(String spanId, String newText) {
    final span = _spanById(spanId);
    if (span == null) return;

    final bool changed = newText != span.text;
    if (changed) {
      if (_edits[spanId] == newText) return;
      _edits[spanId] = newText;
    } else {
      if (!_edits.containsKey(spanId)) return;
      _edits.remove(spanId);
    }
    notifyListeners();
  }

  /// Builds the `edit_text` operations for the pending edits (Req 15.5). Each
  /// op carries the span's page/bbox and original style so the engine can
  /// re-lay the replacement text in the matched font.
  List<OperationModel> buildOperations() {
    final ops = <OperationModel>[];
    for (final entry in _edits.entries) {
      final span = _spanById(entry.key);
      if (span == null) continue;
      ops.add(
        OperationModel(
          type: 'edit_text',
          page: span.page,
          bbox: span.bbox,
          text: entry.value,
          font: span.font,
          size: span.size,
          color: span.color,
        ),
      );
    }
    return ops;
  }

  // --- Apply (Req 15.5) -----------------------------------------------------

  /// Applies the pending text edits via `POST /api/tools/edit/apply`.
  ///
  /// On success the [EditApplyResponse] is stored and the job becomes
  /// downloadable; on an engine error the `{"detail": ...}` message is stored
  /// in [actionError]. A no-op when [canApply] is false. Returns true on
  /// success.
  Future<bool> apply() async {
    if (!canApply) return false;
    final response = _response;
    if (response == null) return false;

    final ops = buildOperations();
    if (ops.isEmpty) return false;

    _applying = true;
    _actionError = null;
    _applyResult = null;
    notifyListeners();

    try {
      final EditApplyResponse res = await _api.editApply(
        EditApplyRequest(jobId: response.jobId, operations: ops),
      );
      _applyResult = res;
      _downloadJobId = response.jobId;
      return true;
    } on ApiException catch (e) {
      _actionError = e.detail;
      return false;
    } finally {
      _applying = false;
      notifyListeners();
    }
  }

  // --- OCR (Req 15.6) -------------------------------------------------------

  /// Runs OCR on the opened PDF via `POST /api/tools/edit/ocr` with the chosen
  /// languages + DPI, then reopens the searchable result as the new editable
  /// source (web parity).
  ///
  /// On success the [OcrResponse] is stored and the job becomes downloadable;
  /// on an engine error the `{"detail": ...}` message is stored in
  /// [actionError]. A no-op when [canRunOcr] is false. Returns true on success.
  Future<bool> runOcr() async {
    if (!canRunOcr) return false;
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return false;

    final int dpi = (ocrDpi ?? EditOcrBounds.dpiDefault)
        .clamp(EditOcrBounds.dpiMin, EditOcrBounds.dpiMax);

    _ocrRunning = true;
    _actionError = null;
    _ocrResult = null;
    notifyListeners();

    try {
      final OcrResponse res = await _api.editOcr(
        fileBytes: bytes,
        filename: name,
        languages: _ocrLanguages.trim(),
        dpi: dpi,
      );
      _ocrResult = res;
      _downloadJobId = res.jobId;

      // The OCR'd file becomes the editable source for its job; reopen it so
      // the now-searchable text spans are editable in place (web `openByJob`).
      try {
        final EditExtractResponse reopened = await _api.editState(res.jobId);
        _response = reopened;
        // _resetEditState clears stale per-document edit state from the old
        // source, but the freshly-OCR'd job must remain downloadable (Req 15.7)
        // and its result summary visible — both share the OCR job id — so
        // restore them after the reset.
        _resetEditState();
        _ocrResult = res;
        _downloadJobId = res.jobId;
        _fileName = _ocrFileName(name);
        _status = EditStatus.ready;
      } on ApiException {
        // Reopen failed (e.g. session expired) — keep the current surface; the
        // OCR'd PDF is still downloadable via _downloadJobId.
      }
      return true;
    } on ApiException catch (e) {
      _actionError = e.detail;
      return false;
    } finally {
      _ocrRunning = false;
      notifyListeners();
    }
  }

  // --- Download (Req 15.7) --------------------------------------------------

  /// Saves the edited / OCR'd PDF via a native Save-As dialog + streamed
  /// download from `GET /api/tools/edit/download/{job_id}` (Req 15.7).
  ///
  /// Returns the [DownloadResult], or null when there is nothing to download. A
  /// failed download surfaces its message in [actionError].
  Future<DownloadResult?> download() async {
    final jobId = _downloadJobId;
    if (jobId == null || busy) return null;

    try {
      return await _downloadService.download(
        engineUrl: _api.editDownloadUri(jobId).toString(),
        suggestedName: _downloadFileName(),
        acceptedTypeGroups: const <XTypeGroup>[_pdfTypeGroup],
      );
    } on DownloadException catch (e) {
      _actionError = e.message;
      notifyListeners();
      return null;
    }
  }

  /// Clears the staged document and returns to the idle open prompt.
  void reset() {
    _status = EditStatus.idle;
    _response = null;
    _fileBytes = null;
    _fileName = null;
    _errorDetail = null;
    _resetEditState();
    notifyListeners();
  }

  // --- Internals ------------------------------------------------------------

  EditableSpanModel? _spanById(String id) {
    for (final span in spans) {
      if (span.id == id) return span;
    }
    return null;
  }

  /// Resets per-document edit/action state (kept together so open, OCR-reopen,
  /// and reset stay consistent).
  void _resetEditState() {
    _selectedSpanId = null;
    _edits.clear();
    _applyResult = null;
    _ocrResult = null;
    _downloadJobId = null;
    _actionError = null;
  }

  /// `scan.pdf` → `scan_ocr.pdf` (mirrors the web naming after OCR).
  static String _ocrFileName(String name) {
    final stem = name.toLowerCase().endsWith('.pdf')
        ? name.substring(0, name.length - 4)
        : name;
    return '${stem}_ocr.pdf';
  }

  /// A sensible suggested name for the saved PDF, derived from the open file.
  String _downloadFileName() {
    final name = _fileName ?? 'document.pdf';
    final stem = name.toLowerCase().endsWith('.pdf')
        ? name.substring(0, name.length - 4)
        : name;
    return '${stem}_edited.pdf';
  }

  /// Save-As filter restricting the edited output to a `.pdf` file.
  static const XTypeGroup _pdfTypeGroup = XTypeGroup(
    label: 'PDF',
    extensions: <String>['pdf'],
    uniformTypeIdentifiers: <String>['com.adobe.pdf'],
    mimeTypes: <String>['application/pdf'],
  );
}
