// Compress tool state + engine wiring (Requirement 13).
//
// [CompressController] is a [ChangeNotifier] that backs the Compress panel. It
// holds the panel's inputs — the selected compression [CompressLevel] and the
// optional target-size-in-MB (constrained to values greater than 0) — plus the
// transient run state (busy flag, the engine's [CompressResponse], and any
// error detail to surface).
//
// It contains ZERO engine logic. Compression itself runs in the Python engine:
// the controller only forwards the picked PDF to `POST /api/tools/compress`
// through the [ApiClient] (which mirrors the engine contract verbatim) and
// streams the result to disk through the [DownloadService]. Per Requirement
// 13.2 it sends EITHER the chosen `level` OR the `target_mb` value: when target
// mode is on it passes `target_mb` (the engine ignores `level` then); otherwise
// it passes `level` alone.

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/foundation.dart';

import '../../../core/api_client.dart';
import '../../../core/download_service.dart';
import '../../../models/tools.dart';

/// Engine-accepted bounds for the Compress controls (Requirement 13.1).
class CompressBounds {
  const CompressBounds._();

  /// `target_mb` must be greater than 0 (`compress_endpoint` rejects `<= 0`).
  /// The web UI seeds the field with `2` and steps by `0.1`.
  static const double targetMbDefault = 2.0;
}

/// The four compression presets the engine accepts for `level`
/// (`light` / `balanced` / `strong` / `extreme`), each mapping to the exact
/// engine value plus the label/blurb the web UI shows on its level cards.
///
/// The `value` strings are the engine's `LEVELS` keys in
/// `app/services/pdf_tools/compress_service.py` — do not rename them.
enum CompressLevel {
  light('light', 'Light', 'Barely touches quality. Great for sharing.'),
  balanced('balanced', 'Balanced', 'Good size cut, still crisp. Recommended.'),
  strong('strong', 'Strong', 'Smaller file, softer images.'),
  extreme('extreme', 'Extreme', 'Smallest file, grayscale, lowest DPI.');

  const CompressLevel(this.value, this.label, this.blurb);

  /// The exact `level` form value the engine expects.
  final String value;

  /// Human-readable title shown on the level card.
  final String label;

  /// Short description shown under the title.
  final String blurb;
}

/// Holds the Compress panel state and drives the engine compress + download.
///
/// The panel is fed a selected PDF through [setFile] (from the native picker or
/// a drop target), then [compress] runs the engine job and [download] saves the
/// result. All three are no-ops when their preconditions aren't met, so the
/// view can bind buttons to them directly and rely on [canRun] / [canDownload]
/// for enablement.
class CompressController extends ChangeNotifier {
  CompressController({
    required ApiClient apiClient,
    required DownloadService downloadService,
  })  : _apiClient = apiClient,
        _downloadService = downloadService;

  final ApiClient _apiClient;
  final DownloadService _downloadService;

  // --- Inputs ---------------------------------------------------------------

  CompressLevel _level = CompressLevel.balanced;
  bool _useTarget = false;
  String _targetMbText = _formatDefaultTarget();

  List<int>? _fileBytes;
  String? _fileName;

  // --- Run state ------------------------------------------------------------

  bool _busy = false;
  CompressResponse? _result;
  String? _errorText;

  /// The selected compression preset (used when [useTarget] is off).
  CompressLevel get level => _level;
  set level(CompressLevel value) {
    if (_level == value) return;
    _level = value;
    notifyListeners();
  }

  /// Whether the panel targets a file size instead of a quality preset. When
  /// on, the engine is driven by [targetMb] and the [level] is ignored
  /// (Requirement 13.2).
  bool get useTarget => _useTarget;
  set useTarget(bool value) {
    if (_useTarget == value) return;
    _useTarget = value;
    notifyListeners();
  }

  /// The raw target-size text exactly as entered (so the field preserves the
  /// user's keystrokes, including a transient empty/invalid value).
  String get targetMbText => _targetMbText;
  set targetMbText(String value) {
    if (_targetMbText == value) return;
    _targetMbText = value;
    notifyListeners();
  }

  /// The parsed target size in MB, or null when the field isn't a number.
  double? get targetMb => double.tryParse(_targetMbText.trim());

  /// Whether the current target entry is valid, i.e. a number greater than 0
  /// (Requirement 13.1). Only meaningful while [useTarget] is on.
  bool get isTargetValid {
    final value = targetMb;
    return value != null && value > 0;
  }

  /// Name of the currently selected PDF, or null when none is loaded.
  String? get fileName => _fileName;

  /// Whether a PDF has been selected.
  bool get hasFile => _fileBytes != null;

  /// Whether a compress run is in flight.
  bool get busy => _busy;

  /// The most recent successful compress result, or null.
  CompressResponse? get result => _result;

  /// The engine error detail to display, or null when there is none
  /// (Requirement 13.5).
  String? get errorText => _errorText;

  /// Whether [compress] can run: a file is loaded, no run is in flight, and —
  /// when targeting a size — the target value is valid.
  bool get canRun => hasFile && !_busy && (!_useTarget || isTargetValid);

  /// Whether a finished result is available to download.
  bool get canDownload => _result != null && !_busy;

  /// Loads a PDF into the panel, clearing any prior result/error so the panel
  /// reflects the new selection.
  void setFile({required List<int> bytes, required String filename}) {
    _fileBytes = bytes;
    _fileName = filename;
    _result = null;
    _errorText = null;
    notifyListeners();
  }

  /// Runs the engine compress job for the selected PDF (Requirement 13.2).
  ///
  /// Sends `target_mb` when [useTarget] is on (the engine ignores `level`
  /// then), otherwise sends the chosen `level`. On success the engine's
  /// [CompressResponse] is stored for display + download (Requirements 13.3,
  /// 13.4); on an engine error the `{"detail": ...}` message is stored in
  /// [errorText] (Requirement 13.5). A no-op when [canRun] is false.
  Future<void> compress() async {
    if (!canRun) return;
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    _busy = true;
    _errorText = null;
    _result = null;
    notifyListeners();

    try {
      final response = await _apiClient.compress(
        fileBytes: bytes,
        filename: name,
        level: _level.value,
        targetMb: _useTarget ? targetMb : null,
      );
      _result = response;
    } on ApiException catch (e) {
      _errorText = e.detail;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Saves the compressed PDF via a native Save-As dialog + streamed download
  /// (Requirement 13.4). Returns the [DownloadResult], or null when there is
  /// nothing to download. A failed download surfaces its message in
  /// [errorText].
  Future<DownloadResult?> download() async {
    final response = _result;
    if (response == null || _busy) return null;

    try {
      final result = await _downloadService.download(
        engineUrl: response.downloadUrl,
        suggestedName: 'compressed.pdf',
        acceptedTypeGroups: const <XTypeGroup>[_pdfTypeGroup],
      );
      return result;
    } on DownloadException catch (e) {
      _errorText = e.message;
      notifyListeners();
      return null;
    }
  }

  /// The fraction of the original size removed, expressed as a whole-number
  /// percentage (matches the web UI's `Math.round(ratio * 100)`), or null when
  /// there is no result yet.
  int? get percentSmaller {
    final response = _result;
    if (response == null) return null;
    return (response.ratio * 100).round();
  }

  /// Save-As filter restricting the compressed output to a `.pdf` file.
  static const XTypeGroup _pdfTypeGroup = XTypeGroup(
    label: 'PDF',
    extensions: <String>['pdf'],
    uniformTypeIdentifiers: <String>['com.adobe.pdf'],
    mimeTypes: <String>['application/pdf'],
  );

  /// Formats the default target so the field starts at `2` (not `2.0`),
  /// matching the web UI's seeded value.
  static String _formatDefaultTarget() {
    const value = CompressBounds.targetMbDefault;
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }
}

/// Formats a byte count the way the web UI's `humanSize` does: `B` under 1 KB,
/// whole `KB` under 1 MB, then one-decimal `MB`.
String humanFileSize(int bytes) {
  final b = bytes < 0 ? 0 : bytes;
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}
