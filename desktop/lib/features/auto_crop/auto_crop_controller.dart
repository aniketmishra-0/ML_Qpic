// Auto Crop form state (Requirements 5.1, 5.2, 5.3).
//
// [AutoCropController] is a [ChangeNotifier] that holds every option the Auto
// Crop tool exposes — the Questions/Solutions toggles and their page ranges,
// the Smart / Online / Answer-sheet toggles, the question-numbering selector,
// and the output configuration (prefixes, start number, image format, JPG
// quality, DPI, padding). It contains NO engine logic: it only validates and
// clamps user input to the engine's accepted bounds so the request the submit
// path builds (tasks 9.2 / 12.5) is always in range.
//
// Every numeric setter clamps to the engine bound and every prefix setter
// truncates to the engine's max length, so the controller's state can never
// hold an out-of-range value regardless of how it is mutated. The values map
// 1:1 onto `ApiClient.crop` / `ApiClient.analyze` parameters, which mirror the
// query parameters declared by `app/routers/crop.py` (`dpi 72–600`,
// `padding 0–200`, `start_number 1–100000`, `jpg_quality 1–100`,
// `question_prefix` / `solution_prefix` max length 10, `marker_style` one of
// auto/q/numbered, `image_format` png/jpg).

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/theme_controller.dart';
import '../../models/analyze.dart';
import '../../models/crop.dart';

/// Engine-accepted bounds for the Auto Crop controls (Requirement 5.3).
///
/// These mirror the `Query(..., ge=, le=, max_length=)` constraints on
/// `crop_pdf` / `analyze_pdf` in `app/routers/crop.py`. They are the single
/// source of truth for both the controller's clamping and the view's
/// input formatters / sliders.
class AutoCropBounds {
  const AutoCropBounds._();

  /// `dpi: int = Query(200, ge=72, le=600)`.
  static const int dpiMin = 72;
  static const int dpiMax = 600;
  static const int dpiDefault = 200;

  /// `padding: int = Query(20, ge=0, le=200)`.
  static const int paddingMin = 0;
  static const int paddingMax = 200;
  static const int paddingDefault = 20;

  /// `start_number: int = Query(1, ge=1, le=100000)`.
  static const int startNumberMin = 1;
  static const int startNumberMax = 100000;
  static const int startNumberDefault = 1;

  /// `jpg_quality: int = Query(90, ge=1, le=100)`.
  static const int jpgQualityMin = 1;
  static const int jpgQualityMax = 100;
  static const int jpgQualityDefault = 90;

  /// `question_prefix` / `solution_prefix` — `Query(max_length=10)`.
  static const int prefixMaxLength = 10;

  /// Clamps [value] into the inclusive `[min, max]` range.
  static int clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

/// The question-numbering selector options, each mapping to the engine's
/// `marker_style` query value (Requirement 5.2): Auto-detect → `auto`,
/// Q-only → `q`, Numbered → `numbered`.
enum NumberingMode {
  /// Detect any supported numbering (`marker_style=auto`).
  autoDetect('auto', 'Auto-detect'),

  /// Only treat `Q1` / `Question 1` markers as questions (`marker_style=q`).
  qOnly('q', 'Q-only'),

  /// Only treat bare `1.` / `2)` numbering as questions
  /// (`marker_style=numbered`).
  numbered('numbered', 'Numbered');

  const NumberingMode(this.markerStyle, this.label);

  /// The exact `marker_style` query value the engine expects.
  final String markerStyle;

  /// Human-readable label shown in the selector.
  final String label;
}

/// Output image format options, each mapping to the engine's `image_format`
/// query value (Requirement 5.3): PNG → `png`, JPG → `jpg`.
enum CropImageFormat {
  /// Lossless PNG output (`image_format=png`).
  png('png', 'PNG'),

  /// Lossy JPG output (`image_format=jpg`); honors [AutoCropController.jpgQuality].
  jpg('jpg', 'JPG');

  const CropImageFormat(this.value, this.label);

  /// The exact `image_format` query value the engine expects.
  final String value;

  /// Human-readable label shown in the selector.
  final String label;
}

/// Which crop archive a download action targets (Requirement 11.1–11.3).
///
/// The engine always produces the [combined] archive; the per-type
/// [questions] / [solutions] archives exist only when that side cropped at
/// least one item, which the engine signals by setting the matching
/// `*_download_url` on the [CropResponse].
enum CropArchive {
  /// The combined questions + solutions ZIP (`download_url`, always present).
  combined,

  /// The questions-only ZIP (`questions_download_url`, when non-null).
  questions,

  /// The solutions-only ZIP (`solutions_download_url`, when non-null).
  solutions,
}

/// Holds and validates the Auto Crop form state and drives the non-Smart crop.
///
/// State getters (typed values plus [markerStyle] / [imageFormatValue] /
/// [useAi]) map 1:1 onto the engine's `POST /api/crop` query parameters, so
/// [crop] builds the request straight from this controller without reshaping
/// anything. The Smart-mode analyze entry (`POST /api/analyze` → Review Canvas)
/// is task 12.5 and is intentionally NOT issued here; [submit] runs the shared
/// pre-request guards for both modes and only performs the direct crop when
/// Smart mode is off.
///
/// There is ZERO engine logic in Dart: detection, cropping and stitching all
/// run in the Python engine. This controller only validates input, forwards the
/// picked PDF to the [ApiClient] (which mirrors the engine contract verbatim),
/// and streams each produced archive to disk through the [DownloadService].
class AutoCropController extends ChangeNotifier {
  /// Creates a controller. [apiClient] and [downloadService] are optional so
  /// the form can be exercised on its own (bounds/clamping) without a live
  /// engine; they are required for [crop] / [analyze] / [download] to issue
  /// requests, and are normally supplied via [bindEngine] once the sidecar
  /// reports ready.
  AutoCropController({
    ApiClient? apiClient,
    DownloadService? downloadService,
  })  : _apiClient = apiClient,
        _downloadService = downloadService;

  ApiClient? _apiClient;
  DownloadService? _downloadService;

  /// The bound API client, or null before the engine is ready.
  ApiClient? get apiClient => _apiClient;

  /// The bound DownloadService, or null before the engine is ready.
  DownloadService? get downloadService => _downloadService;

  /// Whether the engine-backed services are bound (the sidecar is ready).
  bool get engineReady => _apiClient != null && _downloadService != null;

  /// Binds the engine-backed services once the sidecar reports ready (or
  /// re-binds with a fresh Base_URL across a restart). When [downloadService]
  /// is omitted a default one is built from [apiClient]. Mirrors the
  /// `RenameController.bindEngine` pattern so the host (`app.dart`) can attach
  /// the live engine to every feature controller the same way.
  void bindEngine({
    required ApiClient apiClient,
    DownloadService? downloadService,
  }) {
    _apiClient = apiClient;
    _downloadService = downloadService ?? DownloadService(apiClient);
    notifyListeners();
  }

  /// Clears the engine-backed services (e.g. when the engine stops), so the
  /// crop / analyze / download affordances guard against an unavailable engine.
  void unbindEngine() {
    _apiClient = null;
    _downloadService = null;
    notifyListeners();
  }

  // --- Questions / Solutions selection (Requirement 5.1) -------------------

  bool _hasQuestions = true;
  String _questionPages = '';
  bool _hasAnswers = true;
  String _answerPages = '';

  /// Whether the PDF contains a question section (`has_questions`). When off,
  /// the engine ignores [questionPages].
  bool get hasQuestions => _hasQuestions;
  set hasQuestions(bool value) {
    if (_hasQuestions == value) return;
    _hasQuestions = value;
    notifyListeners();
  }

  /// The question page range exactly as entered (`question_pages`), e.g.
  /// `"1-5"` or `"1 to 5, 8"`. Stored verbatim (untrimmed) so the submit
  /// guards (task 9.2) can preserve the user's entry while validating
  /// `.trim().isEmpty` (Requirement 5.5).
  String get questionPages => _questionPages;
  set questionPages(String value) {
    if (_questionPages == value) return;
    _questionPages = value;
    notifyListeners();
  }

  /// Whether the PDF contains a solutions section (`has_answers`). When off,
  /// the engine ignores [answerPages].
  bool get hasAnswers => _hasAnswers;
  set hasAnswers(bool value) {
    if (_hasAnswers == value) return;
    _hasAnswers = value;
    notifyListeners();
  }

  /// The answer/solution page range exactly as entered (`answer_pages`).
  /// Stored verbatim so task 9.2 can preserve it while validating
  /// emptiness (Requirement 5.6).
  String get answerPages => _answerPages;
  set answerPages(String value) {
    if (_answerPages == value) return;
    _answerPages = value;
    notifyListeners();
  }

  // --- Mode toggles + numbering selector (Requirement 5.2) -----------------

  bool _smartMode = true;
  bool _onlineMode = false;
  bool _answerSheet = false;
  NumberingMode _numbering = NumberingMode.autoDetect;

  /// Smart mode: when on, submit calls `POST /api/analyze` and opens the
  /// Review Canvas instead of cropping straight to a ZIP (task 12.5).
  bool get smartMode => _smartMode;
  set smartMode(bool value) {
    if (_smartMode == value) return;
    _smartMode = value;
    notifyListeners();
  }

  /// Online mode: maps to the engine's `use_ai` query parameter, opting into
  /// the AI vision tier when a key is configured.
  bool get onlineMode => _onlineMode;
  set onlineMode(bool value) {
    if (_onlineMode == value) return;
    _onlineMode = value;
    notifyListeners();
  }

  /// Answer-sheet toggle: maps to the engine's `answer_sheet` query parameter.
  bool get answerSheet => _answerSheet;
  set answerSheet(bool value) {
    if (_answerSheet == value) return;
    _answerSheet = value;
    notifyListeners();
  }

  /// The question-numbering selection.
  NumberingMode get numbering => _numbering;
  set numbering(NumberingMode value) {
    if (_numbering == value) return;
    _numbering = value;
    notifyListeners();
  }

  /// The engine `marker_style` value for the current [numbering] selection
  /// (`auto` / `q` / `numbered`). Always one of the three accepted values.
  String get markerStyle => _numbering.markerStyle;

  /// The engine `use_ai` value (true when Online mode is on).
  bool get useAi => _onlineMode;

  // --- Output configuration (Requirement 5.3) ------------------------------

  String _questionPrefix = 'Q';
  String _solutionPrefix = 'S';
  int _startNumber = AutoCropBounds.startNumberDefault;
  CropImageFormat _imageFormat = CropImageFormat.png;
  int _jpgQuality = AutoCropBounds.jpgQualityDefault;
  int _dpi = AutoCropBounds.dpiDefault;
  int _padding = AutoCropBounds.paddingDefault;

  /// Filename prefix for question crops (`question_prefix`). Truncated to
  /// [AutoCropBounds.prefixMaxLength] characters.
  String get questionPrefix => _questionPrefix;
  set questionPrefix(String value) {
    final next = _truncatePrefix(value);
    if (_questionPrefix == next) return;
    _questionPrefix = next;
    notifyListeners();
  }

  /// Filename prefix for solution crops (`solution_prefix`). Truncated to
  /// [AutoCropBounds.prefixMaxLength] characters.
  String get solutionPrefix => _solutionPrefix;
  set solutionPrefix(String value) {
    final next = _truncatePrefix(value);
    if (_solutionPrefix == next) return;
    _solutionPrefix = next;
    notifyListeners();
  }

  /// Number the first cropped item starts at (`start_number`). Clamped to
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

  /// Output image format selection.
  CropImageFormat get imageFormat => _imageFormat;
  set imageFormat(CropImageFormat value) {
    if (_imageFormat == value) return;
    _imageFormat = value;
    notifyListeners();
  }

  /// The engine `image_format` value for the current [imageFormat] selection
  /// (`png` / `jpg`).
  String get imageFormatValue => _imageFormat.value;

  /// JPG compression quality (`jpg_quality`). Clamped to
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

  /// Render DPI (`dpi`). Clamped to
  /// [AutoCropBounds.dpiMin]–[AutoCropBounds.dpiMax].
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

  /// Padding around each crop in pixels (`padding`). Clamped to
  /// [AutoCropBounds.paddingMin]–[AutoCropBounds.paddingMax].
  int get padding => _padding;
  set padding(int value) {
    final next = AutoCropBounds.clamp(
      value,
      AutoCropBounds.paddingMin,
      AutoCropBounds.paddingMax,
    );
    if (_padding == next) return;
    _padding = next;
    notifyListeners();
  }

  /// Truncates a prefix to the engine's max length, preserving the leading
  /// characters the user typed.
  static String _truncatePrefix(String value) {
    if (value.length <= AutoCropBounds.prefixMaxLength) return value;
    return value.substring(0, AutoCropBounds.prefixMaxLength);
  }

  // --- Selected PDF + run state --------------------------------------------

  List<int>? _fileBytes;
  String? _fileName;
  bool _busy = false;
  String? _errorText;
  CropResponse? _result;
  AnalyzeResponse? _analyzeResult;
  List<PageInfo>? _previewPages;
  bool _previewLoading = false;

  /// Name of the currently selected PDF, or null when none is loaded.
  String? get fileName => _fileName;

  /// Whether a PDF has been selected.
  bool get hasFile => _fileBytes != null;

  /// Whether a crop request is in flight.
  bool get busy => _busy;

  /// Cached page previews for the currently selected PDF (the engine-rendered
  /// page images), or null until [loadPreview] has run for this file. Drives
  /// the in-app "View" popup.
  List<PageInfo>? get previewPages => _previewPages;

  /// Whether a preview-render request is in flight (drives the View button's
  /// busy state).
  bool get previewLoading => _previewLoading;

  /// The prompt / engine error to surface above the form, or null when there
  /// is none. Guard prompts (Requirements 5.5–5.7) and the engine `detail`
  /// (Requirement 5.8) both flow through here.
  String? get errorText => _errorText;

  /// The most recent successful crop result, or null. Drives the download
  /// actions (Requirement 5.9, 11.1–11.3).
  CropResponse? get result => _result;

  /// The most recent successful Smart-mode analyze result, or null. The host
  /// observes this to open the Review Canvas after [submit] / [analyze]
  /// (Requirement 6.2). Cleared whenever a new file is loaded or a request
  /// starts so a stale analysis never re-opens the canvas.
  AnalyzeResponse? get analyzeResult => _analyzeResult;

  /// Loads a PDF into the form, clearing any prior result/error so the form
  /// reflects the new selection.
  void setFile({required List<int> bytes, required String filename}) {
    _fileBytes = bytes;
    _fileName = filename;
    _result = null;
    _analyzeResult = null;
    _errorText = null;
    _previewPages = null;
    notifyListeners();
  }

  /// Renders the selected PDF's pages to preview images via the engine's
  /// `POST /api/prepare-manual` rasteriser and caches them on [previewPages]
  /// for the in-app "View" popup. The result is cached so re-opening the popup
  /// for the same file is instant; a new selection clears the cache.
  ///
  /// Returns true once previews are available (freshly rendered or cached). On
  /// an engine error the `{"detail": ...}` message is surfaced via [errorText]
  /// and false is returned. A no-op (returns false) when no PDF is loaded, no
  /// engine is bound, or a render is already in flight.
  Future<bool> loadPreview() async {
    if (_previewPages != null) return true;
    final client = _apiClient;
    final bytes = _fileBytes;
    final name = _fileName;
    if (client == null || bytes == null || name == null || _previewLoading) {
      return false;
    }

    _previewLoading = true;
    _errorText = null;
    notifyListeners();

    try {
      final response = await client.prepareManual(
        fileBytes: bytes,
        filename: name,
        dpi: _dpi,
      );
      _previewPages = response.pages;
      return true;
    } on ApiException catch (e) {
      _errorText = e.detail;
      return false;
    } finally {
      _previewLoading = false;
      notifyListeners();
    }
  }

  /// Clears the form back to its initial state: drops the selected PDF, any
  /// crop / analyze result and error, and resets every option (toggles, page
  /// ranges, numbering, and output / render config) to its default. The engine
  /// binding is preserved so the form stays usable. A no-op while a request is
  /// in flight so a half-finished run isn't torn out from under the engine.
  /// Clears the form back to its initial state: drops the selected PDF, any
  /// crop / analyze result and error, and resets every option (toggles, page
  /// ranges, numbering, and output / render config) to its default. The engine
  /// binding is preserved so the form stays usable. A no-op while a request is
  /// in flight so a half-finished run isn't torn out from under the engine.
  ///
  /// Optionally accepts a [ThemeController] to load user-configured defaults
  /// instead of the hardcoded factory values.
  void reset([ThemeController? defaults]) {
    if (_busy) return;

    // Selected PDF + run state.
    _fileBytes = null;
    _fileName = null;
    _result = null;
    _analyzeResult = null;
    _errorText = null;
    _previewPages = null;

    // Questions / Solutions selection.
    _hasQuestions = true;
    _questionPages = '';
    _hasAnswers = true;
    _answerPages = '';

    // Mode toggles + numbering.
    _smartMode = defaults?.defaultSmartMode ?? true;
    _onlineMode = false;
    _answerSheet = false;
    _numbering = NumberingMode.autoDetect;

    // Output configuration.
    _questionPrefix = defaults?.defaultQuestionPrefix ?? 'Q';
    _solutionPrefix = defaults?.defaultSolutionPrefix ?? 'S';
    _startNumber = AutoCropBounds.startNumberDefault;
    _imageFormat = defaults?.defaultImageFormat == 'jpg'
        ? CropImageFormat.jpg
        : CropImageFormat.png;
    _jpgQuality = AutoCropBounds.jpgQualityDefault;
    _dpi = defaults?.defaultDpi ?? AutoCropBounds.dpiDefault;
    _padding = defaults?.defaultPadding ?? AutoCropBounds.paddingDefault;

    notifyListeners();
  }

  /// Applies default settings loaded from [ThemeController].
  void applyDefaults(ThemeController controller) {
    _questionPrefix = controller.defaultQuestionPrefix;
    _solutionPrefix = controller.defaultSolutionPrefix;
    _imageFormat = controller.defaultImageFormat == 'jpg'
        ? CropImageFormat.jpg
        : CropImageFormat.png;
    _dpi = controller.defaultDpi;
    _padding = controller.defaultPadding;
    _smartMode = controller.defaultSmartMode;
    notifyListeners();
  }

  // --- Submit guards (Requirements 5.5, 5.6, 5.7) --------------------------

  /// Validates the form exactly as the engine would, BEFORE any request is
  /// sent, returning the matching prompt when submission must be blocked or
  /// null when the form is valid. The checks and messages mirror `crop_pdf`
  /// in `app/routers/crop.py` (`ERR_NOTHING_SELECTED`,
  /// `ERR_QUESTION_PAGES_REQUIRED`, `ERR_ANSWER_PAGES_REQUIRED`) so the user
  /// gets the same guidance without a wasted round-trip. Entered values are
  /// never mutated by this check.
  String? validateSubmission() {
    // Both toggles off → nothing to crop (ERR_NOTHING_SELECTED).
    if (!_hasQuestions && !_hasAnswers) {
      return errNothingSelected;
    }
    // Questions on with an empty range (ERR_QUESTION_PAGES_REQUIRED).
    if (_hasQuestions && _questionPages.trim().isEmpty) {
      return errQuestionPagesRequired;
    }
    // Solutions on with an empty range (ERR_ANSWER_PAGES_REQUIRED).
    if (_hasAnswers && _answerPages.trim().isEmpty) {
      return errAnswerPagesRequired;
    }
    return null;
  }

  /// Prompt shown when both the Questions and Solutions toggles are off
  /// (Requirement 5.7). Mirrors the engine's `ERR_NOTHING_SELECTED`.
  static const String errNothingSelected =
      'Turn on the questions toggle, the solutions toggle, or both, and enter '
      'the matching page ranges.';

  /// Prompt shown when Questions is on but its page range is empty
  /// (Requirement 5.5). Mirrors the engine's `ERR_QUESTION_PAGES_REQUIRED`.
  static const String errQuestionPagesRequired =
      "Enter the question pages, e.g. '1-5' or '1 to 5, 8'. Turn off the "
      'questions toggle if this PDF has none.';

  /// Prompt shown when Solutions is on but its page range is empty
  /// (Requirement 5.6). Mirrors the engine's `ERR_ANSWER_PAGES_REQUIRED`.
  static const String errAnswerPagesRequired =
      "Enter the answer / solution pages, e.g. '7-10'. Turn off the solutions "
      'toggle if this PDF has none.';

  // --- Submit + non-Smart crop (Requirements 5.4, 5.8, 5.9) ----------------

  /// Runs the pre-request guards then performs the request matching the mode.
  ///
  /// When [validateSubmission] returns a prompt, submission is blocked: no
  /// request is sent, the entered values are preserved, and the prompt is shown
  /// via [errorText] (Requirements 5.5–5.7). When Smart mode is on, a valid
  /// submit issues `POST /api/analyze` and, on success, stores [analyzeResult]
  /// so the host opens the Review Canvas (Requirement 6.1, 6.2); on an analyze
  /// error the engine `detail` is surfaced and no analysis is stored, so the
  /// canvas is NOT opened (Requirement 6.7). When Smart mode is off, a valid
  /// submit performs the direct crop. Returns true when the request (crop or
  /// analyze) completed successfully.
  Future<bool> submit() async {
    final guard = validateSubmission();
    if (guard != null) {
      _errorText = guard;
      _result = null;
      _analyzeResult = null;
      notifyListeners();
      return false;
    }
    // Smart mode opens the Review Canvas via POST /api/analyze (Req 6.1, 6.2).
    if (_smartMode) {
      return analyze();
    }
    return crop();
  }

  /// Issues `POST /api/crop` for the selected PDF with the controller's mapped
  /// query parameters + the multipart `file` (Requirement 5.4).
  ///
  /// On success the engine's [CropResponse] is stored so the view can present a
  /// download action for each archive it reports as available (Requirement 5.9,
  /// 11.1–11.3). On an engine error the `{"detail": ...}` message is surfaced
  /// via [errorText] (Requirement 5.8). A no-op (returns false) when no PDF is
  /// loaded, a run is already in flight, or no [ApiClient] was provided.
  ///
  /// `question_pages` / `answer_pages` are sent only when their toggle is on,
  /// so a disabled side never leaks a stale range to the engine.
  Future<bool> crop() async {
    final client = _apiClient;
    final bytes = _fileBytes;
    final name = _fileName;
    if (client == null || bytes == null || name == null || _busy) {
      return false;
    }

    _busy = true;
    _errorText = null;
    _result = null;
    notifyListeners();

    try {
      final response = await client.crop(
        fileBytes: bytes,
        filename: name,
        dpi: _dpi,
        padding: _padding,
        markerStyle: markerStyle,
        hasQuestions: _hasQuestions,
        questionPages: _hasQuestions ? _questionPages : null,
        hasAnswers: _hasAnswers,
        answerPages: _hasAnswers ? _answerPages : null,
        questionPrefix: _questionPrefix,
        solutionPrefix: _solutionPrefix,
        startNumber: _startNumber,
        imageFormat: imageFormatValue,
        jpgQuality: _jpgQuality,
        useAi: useAi,
        answerSheet: _answerSheet,
      );
      _result = response;
      return true;
    } on ApiException catch (e) {
      _errorText = e.detail;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // --- Smart analyze entry into the Review Canvas (Req 6.1, 6.2, 6.7) -------

  /// Issues `POST /api/analyze` for the selected PDF with the Smart-mode
  /// parameters and, on success, stores the [AnalyzeResponse] as
  /// [analyzeResult] so the host opens the Review Canvas (Requirement 6.1,
  /// 6.2).
  ///
  /// The query carries exactly the parameters the task and engine contract
  /// require — `dpi`, `marker_style`, `has_questions`, `question_pages`,
  /// `has_answers`, `answer_pages`, `use_ai`, `answer_sheet` — mapped 1:1 from
  /// the form controls, plus the multipart `file`. `question_pages` /
  /// `answer_pages` are sent only when their toggle is on, so a disabled side
  /// never leaks a stale range (the guards in [validateSubmission] already
  /// ensure an enabled side has a non-empty range before this is reached).
  ///
  /// On an engine error the `{"detail": ...}` message is surfaced via
  /// [errorText] and NO analysis is stored, so the host does not open the
  /// canvas (Requirement 6.7). A no-op (returns false) when no PDF is loaded, a
  /// run is already in flight, or no [ApiClient] is bound. The `answer_key_count`
  /// the engine returns rides along on [analyzeResult] and drives the canvas's
  /// answer-sheet messaging (Requirement 6.4, 6.5).
  Future<bool> analyze() async {
    final client = _apiClient;
    final bytes = _fileBytes;
    final name = _fileName;
    if (client == null || bytes == null || name == null || _busy) {
      return false;
    }

    _busy = true;
    _errorText = null;
    _result = null;
    _analyzeResult = null;
    notifyListeners();

    try {
      final response = await client.analyze(
        fileBytes: bytes,
        filename: name,
        dpi: _dpi,
        markerStyle: markerStyle,
        hasQuestions: _hasQuestions,
        questionPages: _hasQuestions ? _questionPages : null,
        hasAnswers: _hasAnswers,
        answerPages: _hasAnswers ? _answerPages : null,
        useAi: useAi,
        answerSheet: _answerSheet,
      );
      _analyzeResult = response;
      return true;
    } on ApiException catch (e) {
      // Surface the engine detail and keep no analysis → canvas stays closed
      // (Requirement 6.7).
      _errorText = e.detail;
      _analyzeResult = null;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Clears the stored [analyzeResult] once the host has opened the Review
  /// Canvas, so returning to the form does not re-open the canvas on the next
  /// rebuild.
  void consumeAnalyzeResult() {
    if (_analyzeResult == null) return;
    _analyzeResult = null;
    notifyListeners();
  }

  // --- Download (Requirements 5.9, 11.1, 11.2, 11.3, 11.4, 11.5) -----------

  /// Whether [archive] is available to download from the current [result].
  ///
  /// The combined archive is always available once a crop succeeds; the
  /// per-type archives are available only when the engine returned a non-null
  /// `questions_download_url` / `solutions_download_url` (Requirement 11.2,
  /// 11.3).
  bool canDownload(CropArchive archive) {
    final response = _result;
    if (response == null || _busy) return false;
    switch (archive) {
      case CropArchive.combined:
        return true;
      case CropArchive.questions:
        return response.questionsDownloadUrl != null;
      case CropArchive.solutions:
        return response.solutionsDownloadUrl != null;
    }
  }

  /// Saves the given [archive] via a native Save-As dialog + streamed download
  /// (Requirements 11.1–11.4, 16). Returns the [DownloadResult], or null when
  /// the archive isn't available or no [DownloadService] was provided. A failed
  /// download surfaces its message in [errorText].
  ///
  /// The download is wired through `GET /api/crop/download/{job_id}` built by
  /// [ApiClient.cropDownloadUri], passing the `kind` of the requested archive
  /// (`combined` / `questions` / `solutions`) plus the controller's configured
  /// `question_prefix` / `solution_prefix` (Requirement 11.4). The engine names
  /// each archive from those prefixes (`Q.zip`, `S.zip`, `QScombined.zip`), so
  /// the Save-As dialog is seeded with the matching suggested filename.
  ///
  /// [canDownload] still gates each archive on the [CropResponse] the engine
  /// returned — combined is always available; the per-type archives only when
  /// the engine reported a non-null `questions_download_url` /
  /// `solutions_download_url` (Requirement 11.2, 11.3). The Answer-sheet toggle
  /// (Requirement 11.5) is carried on the upstream `POST /api/crop` request via
  /// `answer_sheet`, which determines whether the produced archive bundles an
  /// answer sheet; the download endpoint itself takes no `answer_sheet` query.
  Future<DownloadResult?> download(CropArchive archive) async {
    final service = _downloadService;
    final response = _result;
    if (service == null || response == null || !canDownload(archive)) {
      return null;
    }

    // Build the kind/prefix-driven download URL through the same ApiClient the
    // DownloadService streams over, so its Base_URL and connection settings
    // match (Requirement 11.4).
    final Uri downloadUri = service.apiClient.cropDownloadUri(
      response.jobId,
      kind: _kindFor(archive),
      questionPrefix: _questionPrefix,
      solutionPrefix: _solutionPrefix,
    );

    try {
      return await service.download(
        engineUrl: downloadUri.toString(),
        suggestedName: _suggestedNameFor(archive),
        acceptedTypeGroups: const <XTypeGroup>[_zipTypeGroup],
      );
    } on DownloadException catch (e) {
      _errorText = e.message;
      notifyListeners();
      return null;
    }
  }

  /// The engine `kind` query value for [archive] (`combined` / `questions` /
  /// `solutions`), matching the values `download_zip` in `app/routers/crop.py`
  /// accepts.
  static String _kindFor(CropArchive archive) {
    switch (archive) {
      case CropArchive.combined:
        return 'combined';
      case CropArchive.questions:
        return 'questions';
      case CropArchive.solutions:
        return 'solutions';
    }
  }

  /// The Save-As suggested filename for [archive], mirroring the engine's
  /// prefix-based download names (`QScombined.zip`, `Q.zip`, `S.zip`).
  String _suggestedNameFor(CropArchive archive) {
    switch (archive) {
      case CropArchive.combined:
        return '$_questionPrefix${_solutionPrefix}combined.zip';
      case CropArchive.questions:
        return '$_questionPrefix.zip';
      case CropArchive.solutions:
        return '$_solutionPrefix.zip';
    }
  }

  /// Save-As filter restricting crop output to a `.zip` file.
  static const XTypeGroup _zipTypeGroup = XTypeGroup(
    label: 'ZIP archive',
    extensions: <String>['zip'],
    uniformTypeIdentifiers: <String>['public.zip-archive'],
    mimeTypes: <String>['application/zip'],
  );
}
