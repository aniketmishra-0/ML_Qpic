// Preflight tool state + engine wiring (Requirement 14).
//
// [PreflightController] is a [ChangeNotifier] that backs the Preflight panel.
// It holds the panel's inputs — the selected PDF — plus the transient run state
// (busy flag, the engine's [PreflightResponse], the fix-page-sizes config, and
// any error detail to surface).
//
// It contains ZERO engine logic. Preflight inspection and page-size
// normalization run in the Python engine: the controller only forwards the
// picked PDF to `POST /api/tools/preflight` and `POST
// /api/tools/preflight/fix-page-sizes` through the [ApiClient] and streams the
// result to disk through the [DownloadService]. Per Requirement 14.4 it sends
// `target`, `fill_mode` (fit/stretch), and `skip_pages`.

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/foundation.dart';

import '../../../core/api_client.dart';
import '../../../core/download_service.dart';
import '../../../models/tools.dart';

/// The two fill modes the engine accepts for `fill_mode` when fixing page
/// sizes: `fit` (scale content to fit the target, preserving aspect ratio) or
/// `stretch` (stretch content to fill the target exactly).
enum FillMode {
  fit('fit', 'Fit', 'Scale content to fit, preserving aspect ratio.'),
  stretch('stretch', 'Stretch', 'Stretch content to fill the target exactly.');

  const FillMode(this.value, this.label, this.description);

  /// The exact `fill_mode` form value the engine expects.
  final String value;

  /// Human-readable label shown in the UI.
  final String label;

  /// Short description shown under the label.
  final String description;
}

/// Holds the Preflight panel state and drives the engine preflight + fix +
/// download.
///
/// The panel is fed a selected PDF through [setFile] (from the native picker or
/// a drop target), then [runPreflight] runs the engine inspection and
/// [fixPageSizes] normalizes mixed pages. All are no-ops when their
/// preconditions aren't met, so the view can bind buttons to them directly and
/// rely on [canRun] / [canFix] / [canDownload] for enablement.
class PreflightController extends ChangeNotifier {
  PreflightController({
    required ApiClient apiClient,
    required DownloadService downloadService,
  })  : _apiClient = apiClient,
        _downloadService = downloadService;

  final ApiClient _apiClient;
  final DownloadService _downloadService;

  // --- Inputs ---------------------------------------------------------------

  List<int>? _fileBytes;
  String? _fileName;

  // --- Fix page sizes config ------------------------------------------------

  /// The target page size for normalization (e.g. "A4", "Letter", "auto").
  /// Defaults to "auto" which lets the engine pick the most common size.
  String _target = 'auto';

  /// The fill mode: fit or stretch.
  FillMode _fillMode = FillMode.fit;

  /// Pages to skip during normalization (comma-separated page numbers).
  String _skipPages = '';

  // --- Run state ------------------------------------------------------------

  bool _busy = false;
  bool _fixing = false;
  PreflightResponse? _result;
  PreflightFixResponse? _fixResult;
  String? _errorText;

  // --- Getters --------------------------------------------------------------

  /// Name of the currently selected PDF, or null when none is loaded.
  String? get fileName => _fileName;

  /// Whether a PDF has been selected.
  bool get hasFile => _fileBytes != null;

  /// Whether a preflight run is in flight.
  bool get busy => _busy;

  /// Whether a fix-page-sizes run is in flight.
  bool get fixing => _fixing;

  /// The most recent successful preflight result, or null.
  PreflightResponse? get result => _result;

  /// The most recent successful fix-page-sizes result, or null.
  PreflightFixResponse? get fixResult => _fixResult;

  /// The engine error detail to display, or null when there is none
  /// (Requirement 14.6).
  String? get errorText => _errorText;

  /// Whether [runPreflight] can run: a file is loaded and no run is in flight.
  bool get canRun => hasFile && !_busy && !_fixing;

  /// Whether the fix-page-sizes action is available: a preflight result exists
  /// with `mixed_page_sizes == true` and no operation is in flight.
  bool get canFix =>
      hasFile &&
      !_busy &&
      !_fixing &&
      _result != null &&
      _result!.mixedPageSizes;

  /// Whether a finished fix result is available to download.
  bool get canDownload => _fixResult != null && !_busy && !_fixing;

  /// The target page size for normalization.
  String get target => _target;
  set target(String value) {
    if (_target == value) return;
    _target = value;
    notifyListeners();
  }

  /// The fill mode for normalization.
  FillMode get fillMode => _fillMode;
  set fillMode(FillMode value) {
    if (_fillMode == value) return;
    _fillMode = value;
    notifyListeners();
  }

  /// Pages to skip during normalization.
  String get skipPages => _skipPages;
  set skipPages(String value) {
    if (_skipPages == value) return;
    _skipPages = value;
    notifyListeners();
  }

  // --- Actions --------------------------------------------------------------

  /// Loads a PDF into the panel, clearing any prior result/error so the panel
  /// reflects the new selection.
  void setFile({required List<int> bytes, required String filename}) {
    _fileBytes = bytes;
    _fileName = filename;
    _result = null;
    _fixResult = null;
    _errorText = null;
    notifyListeners();
  }

  /// Runs the engine preflight inspection for the selected PDF (Req 14.1).
  ///
  /// On success the engine's [PreflightResponse] is stored for display
  /// (Req 14.2); on an engine error the `{"detail": ...}` message is stored in
  /// [errorText] (Req 14.6). A no-op when [canRun] is false.
  Future<void> runPreflight() async {
    if (!canRun) return;
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    _busy = true;
    _errorText = null;
    _result = null;
    _fixResult = null;
    notifyListeners();

    try {
      final response = await _apiClient.preflight(
        fileBytes: bytes,
        filename: name,
      );
      _result = response;
    } on ApiException catch (e) {
      _errorText = e.detail;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Runs the engine page-size fix for the selected PDF (Req 14.4).
  ///
  /// Sends `target`, `fill_mode`, and `skip_pages`. On success the engine's
  /// [PreflightFixResponse] is stored for display + download (Req 14.5); on an
  /// engine error the `{"detail": ...}` message is stored in [errorText]
  /// (Req 14.6). A no-op when [canFix] is false.
  Future<void> fixPageSizes() async {
    if (!canFix) return;
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    _fixing = true;
    _errorText = null;
    _fixResult = null;
    notifyListeners();

    try {
      final response = await _apiClient.preflightFixPageSizes(
        fileBytes: bytes,
        filename: name,
        target: _target,
        fillMode: _fillMode.value,
        skipPages: _skipPages,
      );
      _fixResult = response;
    } on ApiException catch (e) {
      _errorText = e.detail;
    } finally {
      _fixing = false;
      notifyListeners();
    }
  }

  /// Saves the normalized PDF via a native Save-As dialog + streamed download
  /// (Req 14.5). Returns the [DownloadResult], or null when there is nothing
  /// to download. A failed download surfaces its message in [errorText].
  Future<DownloadResult?> download() async {
    final response = _fixResult;
    if (response == null || _busy || _fixing) return null;

    try {
      final result = await _downloadService.download(
        engineUrl: response.downloadUrl,
        suggestedName: 'normalized.pdf',
        acceptedTypeGroups: const <XTypeGroup>[_pdfTypeGroup],
      );
      return result;
    } on DownloadException catch (e) {
      _errorText = e.message;
      notifyListeners();
      return null;
    }
  }

  /// Save-As filter restricting the normalized output to a `.pdf` file.
  static const XTypeGroup _pdfTypeGroup = XTypeGroup(
    label: 'PDF',
    extensions: <String>['pdf'],
    uniformTypeIdentifiers: <String>['com.adobe.pdf'],
    mimeTypes: <String>['application/pdf'],
  );
}
