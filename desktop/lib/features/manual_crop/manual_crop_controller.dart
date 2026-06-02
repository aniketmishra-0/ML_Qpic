// Manual Crop tool state (Requirements 7.1, 7.2, 7.3, 7.6).
//
// [ManualCropController] is a [ChangeNotifier] that backs the Manual Crop tool:
// the user opens a PDF, the engine rasterises every page (no detection), and
// the shared Review Canvas opens with an EMPTY item list so the user can
// hand-draw every crop.
//
// INDEPENDENT OUTPUT FIELDS (Req 7.3): this controller holds its OWN
// `question_prefix`, `solution_prefix`, `start_number`, `image_format`, and
// `jpg_quality`, kept in fields entirely separate from the Auto Crop tool's
// [AutoCropController]. Because each tool owns its own controller instance,
// changing one tool's field never alters the other's. The accepted *bounds*
// (and the PNG/JPG enum) are the engine's contract, so they are reused from
// [AutoCropBounds] / [CropImageFormat] as a single source of truth — only the
// VALUES are per-tool.
//
// OPEN FLOW (Req 7.1, 7.2): [open] calls `POST /api/prepare-manual` with the
// query `dpi`, then loads the returned page previews into the shared
// [ReviewController] via `loadFromManual` (empty items, no notes, no answer
// key) and flips [canvasOpen] true so the host shows the Review Canvas. Each
// page preview is fetched from its engine-provided `preview_url` against the
// Base_URL (the host wires [ApiClient.resolveUri] as the canvas's preview
// resolver).
//
// ERROR PATH (Req 7.6): if `prepare-manual` returns an error (e.g. a non-PDF
// upload rejected with HTTP 400), the canvas is NOT opened and the engine's
// `{"detail": ...}` message is surfaced via [errorText].
//
// SCOPE: the manual FINALIZE (with the empty-list guard and item retention on
// error) is wired here (task 13.2): [finalize] delegates to the shared
// [ReviewController.finalize] with this tool's OWN output config (Req 7.4),
// relying on the shared controller's empty-list guard (Req 7.5) and
// item-retention-on-error (Req 7.7). There is ZERO engine logic in Dart: all
// rasterising and cropping happen in the Python engine, reached over localhost
// HTTP; this controller only validates input and shuttles bytes.

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/file_picker_service.dart';
import '../auto_crop/auto_crop_controller.dart'
    show AutoCropBounds, CropImageFormat;
import '../review/review_controller.dart';

/// Holds the Manual Crop output configuration and drives the open-PDF →
/// prepare-manual → Review Canvas flow.
///
/// The output config ([questionPrefix], [solutionPrefix], [startNumber],
/// [imageFormat], [jpgQuality]) is independent of the Auto Crop tool's
/// (Req 7.3) and maps 1:1 onto the finalize payload task 13.2 builds. [open]
/// performs the `POST /api/prepare-manual` call and opens the shared
/// [ReviewController]; on an engine error the canvas stays closed and the
/// `detail` is surfaced (Req 7.6).
class ManualCropController extends ChangeNotifier {
  /// Creates a controller. [apiClient] / [downloadService] are optional so the
  /// form (output-config clamping) can be exercised without a live engine; they
  /// are required for [open] to issue the prepare-manual request and are
  /// normally supplied via [bindEngine] once the sidecar reports ready.
  /// [filePickerService] backs [pickPdf]. An existing [reviewController] may be
  /// injected (e.g. by a test or a shared host); when omitted a fresh one is
  /// created and owned (disposed) by this controller.
  ManualCropController({
    ApiClient? apiClient,
    DownloadService? downloadService,
    FilePickerService filePickerService = const FilePickerService(),
    ReviewController? reviewController,
  })  : _apiClient = apiClient,
        _downloadService = downloadService,
        _filePickerService = filePickerService,
        _ownsReview = reviewController == null,
        review = reviewController ?? ReviewController() {
    review.addListener(_onReviewChanged);
    // When an engine is supplied at construction (e.g. in tests), bind it onto
    // the shared review session too so the manual finalize/download (Req 7.4)
    // and snap (Req 9) reach it. `bindEngine` (the normal path on sidecar
    // ready) does the same propagation.
    if (apiClient != null) {
      review.bindEngine(
        apiClient: apiClient,
        downloadService: downloadService ?? DownloadService(apiClient),
      );
    }
  }

  ApiClient? _apiClient;
  DownloadService? _downloadService;
  final FilePickerService _filePickerService;

  /// The shared Review Canvas session, loaded from `POST /api/prepare-manual`
  /// (Req 7.2). The Manual Crop tool starts it with an empty item list so every
  /// crop is hand-drawn. The finalize wiring (task 13.2) reads from here.
  final ReviewController review;
  final bool _ownsReview;

  /// The bound API client, or null before the engine is ready.
  ApiClient? get apiClient => _apiClient;

  /// The bound download service (used by the finalize/download path in
  /// task 13.2), or null before the engine is ready.
  DownloadService? get downloadService => _downloadService;

  /// Whether the engine-backed services are bound (the sidecar is ready).
  bool get engineReady => _apiClient != null;

  /// Binds the engine-backed services once the sidecar reports ready (or
  /// re-binds with a fresh Base_URL across a restart). When [downloadService]
  /// is omitted a default one is built from [apiClient].
  ///
  /// The SAME services are bound onto the shared [review] session so that the
  /// manual finalize + download (task 13.2, Req 7.4) and snap-to-content
  /// (Req 9) reach the live engine. Without this propagation
  /// [ReviewController.finalize] would be a no-op (it guards against an unbound
  /// engine), so the manual Finalize control would never issue
  /// `POST /api/finalize`.
  void bindEngine({
    required ApiClient apiClient,
    DownloadService? downloadService,
  }) {
    _apiClient = apiClient;
    final service = downloadService ?? DownloadService(apiClient);
    _downloadService = service;
    review.bindEngine(apiClient: apiClient, downloadService: service);
    notifyListeners();
  }

  /// Clears the engine-backed services (e.g. when the engine stops), so the
  /// open and finalize affordances guard against an unavailable engine. Also
  /// unbinds the shared [review] session.
  void unbindEngine() {
    _apiClient = null;
    _downloadService = null;
    review.unbindEngine();
    notifyListeners();
  }

  // --- Independent output configuration (Req 7.3) --------------------------

  String _questionPrefix = 'Q';
  String _solutionPrefix = 'S';
  int _startNumber = AutoCropBounds.startNumberDefault;
  CropImageFormat _imageFormat = CropImageFormat.png;
  int _jpgQuality = AutoCropBounds.jpgQualityDefault;
  int _dpi = AutoCropBounds.dpiDefault;

  /// Filename prefix for question crops (`question_prefix`), independent of the
  /// Auto Crop tool's. Truncated to [AutoCropBounds.prefixMaxLength] chars.
  String get questionPrefix => _questionPrefix;
  set questionPrefix(String value) {
    final next = _truncatePrefix(value);
    if (_questionPrefix == next) return;
    _questionPrefix = next;
    notifyListeners();
  }

  /// Filename prefix for solution crops (`solution_prefix`), independent of the
  /// Auto Crop tool's. Truncated to [AutoCropBounds.prefixMaxLength] chars.
  String get solutionPrefix => _solutionPrefix;
  set solutionPrefix(String value) {
    final next = _truncatePrefix(value);
    if (_solutionPrefix == next) return;
    _solutionPrefix = next;
    notifyListeners();
  }

  /// Number the first cropped item starts at (`start_number`), independent of
  /// the Auto Crop tool's. Clamped to
  /// [AutoCropBounds.startNumberMin]–[AutoCropBounds.startNumberMax].
  int get startNumber => _startNumber;
  set startNumber(int value) {
    final next = AutoCropBounds.clamp(
      value,
      AutoCropBounds.startNumberMin,
      AutoCropBounds.startNumberMax,
    );
    if (_startNumber == next) return;
    _startNumber = next;
    notifyListeners();
  }

  /// Output image format selection (`image_format` png/jpg), independent of the
  /// Auto Crop tool's.
  CropImageFormat get imageFormat => _imageFormat;
  set imageFormat(CropImageFormat value) {
    if (_imageFormat == value) return;
    _imageFormat = value;
    notifyListeners();
  }

  /// The engine `image_format` value for the current [imageFormat] (`png`/`jpg`).
  String get imageFormatValue => _imageFormat.value;

  /// JPG compression quality (`jpg_quality`, 1–100), independent of the Auto
  /// Crop tool's. Clamped to
  /// [AutoCropBounds.jpgQualityMin]–[AutoCropBounds.jpgQualityMax]. Ignored by
  /// the engine for PNG output.
  int get jpgQuality => _jpgQuality;
  set jpgQuality(int value) {
    final next = AutoCropBounds.clamp(
      value,
      AutoCropBounds.jpgQualityMin,
      AutoCropBounds.jpgQualityMax,
    );
    if (_jpgQuality == next) return;
    _jpgQuality = next;
    notifyListeners();
  }

  /// Render DPI passed to `POST /api/prepare-manual` as the `dpi` query param
  /// (Req 7.1). Clamped to [AutoCropBounds.dpiMin]–[AutoCropBounds.dpiMax].
  int get dpi => _dpi;
  set dpi(int value) {
    final next = AutoCropBounds.clamp(
      value,
      AutoCropBounds.dpiMin,
      AutoCropBounds.dpiMax,
    );
    if (_dpi == next) return;
    _dpi = next;
    notifyListeners();
  }

  static String _truncatePrefix(String value) {
    if (value.length <= AutoCropBounds.prefixMaxLength) return value;
    return value.substring(0, AutoCropBounds.prefixMaxLength);
  }

  // --- Selected PDF + open/run state ---------------------------------------

  List<int>? _fileBytes;
  String? _fileName;
  bool _busy = false;
  String? _errorText;
  bool _canvasOpen = false;

  /// Name of the currently selected PDF, or null when none is loaded.
  String? get fileName => _fileName;

  /// Whether a PDF has been selected.
  bool get hasFile => _fileBytes != null;

  /// Whether a prepare-manual request is in flight.
  bool get busy => _busy;

  /// The engine error `detail` (or a transport message) to surface above the
  /// form, or null when there is none (Req 7.6).
  String? get errorText => _errorText;

  /// Whether the Review Canvas is open (prepare-manual succeeded). The host
  /// shows the canvas when true and the open form when false.
  bool get canvasOpen => _canvasOpen;

  /// Loads a PDF into the tool, clearing any prior error so the form reflects
  /// the new selection. Does not call the engine; use [open] to open it.
  void setFile({required List<int> bytes, required String filename}) {
    _fileBytes = bytes;
    _fileName = filename;
    _errorText = null;
    notifyListeners();
  }

  // --- Open: prepare-manual → Review Canvas (Req 7.1, 7.2, 7.6) ------------

  /// Opens the currently selected PDF for manual cropping (Req 7.1, 7.2).
  ///
  /// Calls `POST /api/prepare-manual` with the `dpi` query param + the
  /// multipart `file`; on success loads the returned page previews into the
  /// shared [review] session with an EMPTY item list (Req 7.2) and flips
  /// [canvasOpen] true. On an engine error the `{"detail": ...}` message is
  /// surfaced via [errorText] and the canvas is NOT opened (Req 7.6). A no-op
  /// (returns false) when no PDF is loaded, a run is already in flight, or no
  /// [ApiClient] is bound.
  Future<bool> open() async {
    final client = _apiClient;
    final bytes = _fileBytes;
    final name = _fileName;
    if (client == null || bytes == null || name == null || _busy) {
      return false;
    }

    _busy = true;
    _errorText = null;
    notifyListeners();

    try {
      final response = await client.prepareManual(
        fileBytes: bytes,
        filename: name,
        dpi: _dpi,
      );
      // Load the page previews with an empty item list — every crop is drawn by
      // hand in the canvas (Req 7.2).
      review.loadFromManual(response);
      _canvasOpen = true;
      return true;
    } on ApiException catch (e) {
      // Do NOT open the canvas; surface the engine detail (Req 7.6).
      _errorText = e.detail;
      _canvasOpen = false;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Opens the native PDF picker (Req 17.1), loads the chosen file, and opens
  /// it in the Review Canvas in one step (the "open a PDF in Manual Crop"
  /// action, Req 7.1). A no-op when the user cancels the dialog. Returns true
  /// when the canvas opened.
  Future<bool> pickPdf() async {
    final XFile? picked = await _filePickerService.pickPdf();
    if (picked == null) return false;
    final bytes = await picked.readAsBytes();
    setFile(bytes: bytes, filename: picked.name);
    return open();
  }

  /// Closes the Review Canvas and returns to the open form, clearing the review
  /// session. Keeps the output config and the selected PDF so the user can
  /// reopen with the same settings.
  void closeCanvas() {
    if (!_canvasOpen) return;
    _canvasOpen = false;
    review.reset();
    notifyListeners();
  }

  // --- Finalize (Req 7.4, 7.5, 7.7) ----------------------------------------

  /// Whether a `POST /api/finalize` request is in flight (forwarded from the
  /// shared [review] session).
  bool get finalizing => review.finalizing;

  /// The engine `detail` (or the empty-list prompt) from the last finalize
  /// attempt, or null. Surfaced on the Review Canvas (Req 7.5, 7.7).
  String? get finalizeError => review.finalizeError;

  /// Finalizes the hand-drawn manual crop set into the downloadable ZIP
  /// (Req 7.4).
  ///
  /// Delegates to [ReviewController.finalize] with the Manual Crop tool's OWN
  /// output config — its independent [questionPrefix], [solutionPrefix],
  /// [startNumber], [imageFormatValue], and [jpgQuality] (Req 7.3/7.4) — plus
  /// this tool's render [dpi]. Because a Manual Crop session carries no detected
  /// answer key (`answerKeyCount` is null), `answer_sheet` resolves to false: a
  /// manual crop never bundles an answer sheet.
  ///
  /// The shared controller enforces the task's guards:
  ///   * an EMPTY item list blocks finalize, sends no request, and surfaces the
  ///     "draw at least one crop" prompt via [finalizeError] (Req 7.5);
  ///   * an engine error retains the hand-drawn items so the user can fix and
  ///     retry, surfacing the engine `detail` (Req 7.7).
  ///
  /// Returns true only when the engine accepted the crop. A no-op (returns
  /// false) when no engine is bound or a run is already in flight.
  Future<bool> finalize() {
    return review.finalize(
      dpi: _dpi,
      questionPrefix: _questionPrefix,
      solutionPrefix: _solutionPrefix,
      startNumber: _startNumber,
      imageFormat: _imageFormat.value,
      jpgQuality: _jpgQuality,
    );
  }

  // --- Internals -----------------------------------------------------------

  void _onReviewChanged() => notifyListeners();

  @override
  void dispose() {
    review.removeListener(_onReviewChanged);
    if (_ownsReview) review.dispose();
    super.dispose();
  }
}
