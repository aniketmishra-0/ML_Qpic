// Review session controller + state (Req 6.2, 8.6, 8.7, 8.12, 8.13).
//
// [ReviewController] is the single session-level orchestrator for the Review
// Canvas, shared by BOTH Smart Auto Crop (loaded from `POST /api/analyze`) and
// Manual Crop (loaded from `POST /api/prepare-manual`). It owns the engine
// session identity (`jobId`, `answerKeyCount`, which tool opened it) and wraps
// the interim [ReviewCanvasController] (task 11.5) for every canvas-input
// operation — page navigation, zoom/pan, hover/hit-test, drawing, additive
// re-select, and per-box delete.
//
// WHY WRAP RATHER THAN FOLD (the 11.5 seam decision):
// Task 11.5 deliberately put all canvas-input state and gesture operations into
// [ReviewCanvasController], and the `ReviewCanvas` widget + its tests bind to
// that class. Folding those fields into a fresh state object would duplicate
// the source of truth and force the widget/tests to be rewritten. Wrapping
// keeps ONE source of truth (the canvas controller) for the page/items/notes/
// view-transform fields, while this controller adds only the session fields the
// canvas layer has no business owning (`jobId`, `answerKeyCount`, `source`) and
// the load/finalize plumbing. The widget keeps talking to [canvas]; this layer
// is purely additive. This is the "wrap the interim controller" path the design
// and the 11.5 seam note call out as clean.
//
// REUSE BY BOTH TOOLS (Req 6.2, 7.x): [loadFromAnalyze] and [loadFromManual]
// are the two entry points; everything downstream (canvas behaviour, re-select,
// finalize payload) is identical, so the same canvas reaches parity for both.
//
// ADDITIVE RE-SELECT (Req 8.6) + "DONE" CLEANUP (Req 8.7): both are implemented
// by the wrapped [ReviewCanvasController] (`startEditing` → append-only commits
// that lock segment order, set `source = manual`, clear `flagged`, and drop the
// matching note; `stopEditing` removes an item left with zero segments). This
// controller exposes them as session-level affordances ([startReselectForItem],
// [startReselectForNote], [doneReselecting]) so the notes panel (task 12.4) and
// canvas toolbar can drive re-select without reaching into the canvas layer.
//
// SEAMS FOR LATER TASKS — structured here, implemented elsewhere:
//   * Snap (task 12.2): [attachSnap] installs a [SegmentInterceptor] that calls
//     `POST /api/snap` on box-end (while [snapEnabled]) and replaces the box
//     with the tightened rect, falling back to the drawn box on error/unchanged
//     (Req 9). The HTTP call itself lives in `snap_interceptor.dart`.
//   * Notes panel (task 12.4): [notes] + [startReselectForNote] expose the data
//     and the Fix action's controller side; the panel widget is built in 12.4.
//   * Analyze entry (task 12.5): [loadFromAnalyze] populates state; the API call,
//     opening the canvas, and answer-sheet messaging UI live in 12.5.
//   * Finalize (task 12.6): [toFinalizeItems] / [buildFinalizeRequest] assemble
//     the payload from kept items; the `POST /api/finalize` call + download are
//     in 12.6.
//
// Engine boundary: ZERO engine logic in Dart. Loading copies the engine's own
// JSON (page-percentage coordinates, notes, answer-key count); the snap and
// finalize SEAMS only shape request objects — the HTTP calls and all detection/
// crop/stitch work stay in the Python engine, reached over localhost HTTP by
// later tasks.

import 'dart:ui' show Offset;

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../models/analyze.dart';
import '../../models/crop.dart';
import '../auto_crop/auto_crop_controller.dart' show CropArchive;
import 'canvas_geometry.dart' show kFitWidthZoom;
import 'review_canvas_controller.dart';
import 'snap_interceptor.dart';

/// Which tool opened the current review session.
///
/// The canvas behaves identically for both, but the session differs: Smart Auto
/// Crop carries a detected answer-key count (so the finalize download may
/// include an answer sheet), while Manual Crop starts empty with no answer key.
enum ReviewSource {
  /// Opened from Smart Auto Crop via `POST /api/analyze`.
  smartAutoCrop,

  /// Opened from Manual Crop via `POST /api/prepare-manual`.
  manualCrop,
}

/// An immutable snapshot of the review session, exactly the fields the design's
/// `ReviewState` enumerates: `jobId`, `pages`, `items`, `notes`,
/// `currentPageIndex`, `editingIndex`, `zoom`, `pan`, and `answerKeyCount`
/// (plus the originating [source]).
///
/// This is a read view produced by [ReviewController.state]; the live mutable
/// state lives in the controller (and its wrapped [ReviewCanvasController]) so
/// there is a single source of truth. Consumers (notes panel, finalize builder,
/// answer-sheet messaging) read this snapshot rather than poking at the canvas.
@immutable
class ReviewState {
  /// Creates a snapshot. Lists are stored as-is; callers in [ReviewController]
  /// already pass unmodifiable views.
  const ReviewState({
    required this.jobId,
    required this.pages,
    required this.items,
    required this.notes,
    required this.currentPageIndex,
    required this.editingIndex,
    required this.zoom,
    required this.pan,
    required this.source,
    this.answerKeyCount,
    this.methodUsed,
  });

  /// The empty/initial state before any session is loaded.
  static const ReviewState empty = ReviewState(
    jobId: '',
    pages: <PageInfo>[],
    items: <AnalyzedItem>[],
    notes: <ReviewNote>[],
    currentPageIndex: 0,
    editingIndex: -1,
    zoom: kFitWidthZoom,
    pan: Offset.zero,
    source: ReviewSource.smartAutoCrop,
    answerKeyCount: null,
    methodUsed: null,
  );

  /// Engine crop/analyze job id used by snap (12.2) and finalize (12.6).
  final String jobId;

  /// All pages in review order (absolute page number + `preview_url`).
  final List<PageInfo> pages;

  /// All review items (auto-detected and/or hand-drawn).
  final List<AnalyzedItem> items;

  /// Review advisories returned by the engine; re-selecting/overlap-replacing
  /// an item clears the matching note.
  final List<ReviewNote> notes;

  /// Index into [pages] of the page currently shown (clamped to range).
  final int currentPageIndex;

  /// Index into [items] of the item being re-selected, or `-1` when not
  /// re-selecting (Req 8.6).
  final int editingIndex;

  /// Current zoom factor, always within 0.25..6.0 (Req 8.9).
  final double zoom;

  /// Current pan/scroll translation in widget px; never affects a box's
  /// page-percentage coordinates (Req 8.8).
  final Offset pan;

  /// Which tool opened this session.
  final ReviewSource source;

  /// Answers parsed from the paper's answer key for a Smart Auto Crop session
  /// (`> 0` ⇒ the finalized download will include an answer sheet, Req 6.4/6.5),
  /// or `null` for Manual Crop where no answer key is detected.
  final int? answerKeyCount;

  /// The method used for detection (e.g. 'local_ml', 'ocr').
  final String? methodUsed;

  /// Whether a re-select session is active.
  bool get isEditing => editingIndex >= 0;

  /// Whether any pages are loaded.
  bool get hasPages => pages.isNotEmpty;

  /// The absolute (1-indexed) page number currently shown.
  int get currentPageNumber =>
      pages.isNotEmpty ? pages[currentPageIndex].page : 1;

  /// Whether finalizing this session will include an answer sheet (Req 6.4):
  /// true only when a positive [answerKeyCount] was detected.
  bool get finalizeWillIncludeAnswerSheet => (answerKeyCount ?? 0) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReviewState &&
      other.jobId == jobId &&
      listEquals(other.pages, pages) &&
      listEquals(other.items, items) &&
      listEquals(other.notes, notes) &&
      other.currentPageIndex == currentPageIndex &&
      other.editingIndex == editingIndex &&
      other.zoom == zoom &&
      other.pan == pan &&
      other.source == source &&
      other.answerKeyCount == answerKeyCount &&
      other.methodUsed == methodUsed;

  @override
  int get hashCode => Object.hash(
        jobId,
        Object.hashAll(pages),
        Object.hashAll(items),
        Object.hashAll(notes),
        currentPageIndex,
        editingIndex,
        zoom,
        pan,
        source,
        answerKeyCount,
        methodUsed,
      );

  @override
  String toString() =>
      'ReviewState(jobId: $jobId, source: $source, pages: ${pages.length}, '
      'items: ${items.length}, notes: ${notes.length}, '
      'currentPageIndex: $currentPageIndex, editingIndex: $editingIndex, '
      'zoom: $zoom, pan: $pan, answerKeyCount: $answerKeyCount, methodUsed: $methodUsed)';
}

/// Session-level controller for the Review Canvas, reused by Smart Auto Crop
/// (via [loadFromAnalyze]) and Manual Crop (via [loadFromManual]).
///
/// Wraps a [ReviewCanvasController] for all canvas-input operations and adds the
/// engine session fields (`jobId`, `answerKeyCount`, [source]). It forwards the
/// canvas controller's change notifications so a single listener here sees every
/// change (gesture or session). The [ReviewCanvas] widget binds to [canvas]
/// directly, so this layer is purely additive.
class ReviewController extends ChangeNotifier {
  /// Creates a controller, optionally over an existing [canvas] (e.g. one a
  /// test or the canvas widget already holds). When [canvas] is omitted, a
  /// fresh empty [ReviewCanvasController] is created and owned (disposed) by
  /// this controller. When a [canvas] is supplied, this controller does NOT
  /// dispose it unless [ownsCanvas] is explicitly set true, so a widget can
  /// keep ownership of a shared canvas.
  ///
  /// When an [apiClient] is supplied, snap-to-content (Req 9) is wired
  /// automatically: a [SegmentInterceptor] is installed on the canvas that
  /// calls `POST /api/snap` on box-end while [snapEnabled] is true, replacing
  /// the drawn box with the tightened rect and falling back to the drawn box on
  /// any error/unchanged response. Omit [apiClient] (e.g. in pure canvas tests)
  /// to leave the snap seam untouched.
  ReviewController({
    ReviewCanvasController? canvas,
    bool ownsCanvas = false,
    ApiClient? apiClient,
    DownloadService? downloadService,
  })  : _canvas = canvas ?? ReviewCanvasController(),
        _ownsCanvas = canvas == null || ownsCanvas {
    _canvas.addListener(_onCanvasChanged);
    if (apiClient != null) {
      bindEngine(apiClient: apiClient, downloadService: downloadService);
    }
  }

  /// The wrapped canvas-input controller (task 11.5). The `ReviewCanvas` widget
  /// binds to this; feature screens can also drive canvas operations through it
  /// or through the forwarding helpers on this controller.
  final ReviewCanvasController _canvas;
  final bool _ownsCanvas;

  ApiClient? _apiClient;
  DownloadService? _downloadService;
  String _jobId = '';
  int? _answerKeyCount;
  String? _methodUsed;
  ReviewSource _source = ReviewSource.smartAutoCrop;
  bool _snapEnabled = true;

  // Finalize run state (task 12.6).
  bool _finalizing = false;
  String? _finalizeError;
  CropResponse? _finalizeResult;
  String _finalizeQuestionPrefix = 'Q';
  String _finalizeSolutionPrefix = 'S';
  bool _autoDetecting = false;

  /// Whether an auto-detection request is in flight.
  bool get autoDetecting => _autoDetecting;

  // Output config used for per-item previews so a preview render matches the
  // finalized download exactly (same DPI / padding / format). The host keeps
  // these in step with the active tool's output config via [setPreviewOutput];
  // they default to the engine's own defaults.
  int _previewDpi = 200;
  int _previewPadding = 20;
  String _previewImageFormat = 'png';
  int _previewJpgQuality = 90;

  /// The wrapped canvas-input controller.
  ReviewCanvasController get canvas => _canvas;

  // ---- Engine binding (tasks 12.2 snap / 12.6 finalize+download) ----------

  /// The bound API client, or null before the engine is ready.
  ApiClient? get apiClient => _apiClient;

  /// The bound download service, or null before the engine is ready.
  DownloadService? get downloadService => _downloadService;

  /// Whether the engine-backed services are bound (the sidecar is ready).
  bool get engineReady => _apiClient != null && _downloadService != null;

  /// Binds the engine-backed services once the sidecar reports ready (or
  /// re-binds with a fresh Base_URL across a restart). Wires snap-to-content
  /// (Req 9) via [attachSnap] and enables finalize + download (Req 6.6,
  /// 11.1–11.5). When [downloadService] is omitted a default one is built from
  /// [apiClient], mirroring the `AutoCropController.bindEngine` pattern so the
  /// host (`app.dart`) can attach the live engine the same way.
  void bindEngine({
    required ApiClient apiClient,
    DownloadService? downloadService,
  }) {
    _apiClient = apiClient;
    _downloadService = downloadService ?? DownloadService(apiClient);
    attachSnap(apiClient);
    notifyListeners();
  }

  /// Clears the engine-backed services (e.g. when the engine stops), so the
  /// finalize/download affordances guard against an unavailable engine. The
  /// snap interceptor is left attached but becomes a no-op without a live
  /// client; re-binding restores it.
  void unbindEngine() {
    _apiClient = null;
    _downloadService = null;
    notifyListeners();
  }

  // ---- Session identity ---------------------------------------------------

  /// Engine crop/analyze job id used by snap (12.2) and finalize (12.6).
  String get jobId => _jobId;

  /// Answers parsed from the paper's answer key (Smart Auto Crop), or null for
  /// Manual Crop. See [ReviewState.answerKeyCount].
  int? get answerKeyCount => _answerKeyCount;

  /// The method used by the engine for auto detection.
  String? get methodUsed => _methodUsed;

  /// Which tool opened the current session.
  ReviewSource get source => _source;

  /// Whether finalizing will include an answer sheet (Req 6.4/6.5).
  bool get finalizeWillIncludeAnswerSheet => (_answerKeyCount ?? 0) > 0;

  // ---- Delegated read views (single source of truth: [_canvas]) ----------

  /// All pages in review order.
  List<PageInfo> get pages => _canvas.pages;

  /// All review items.
  List<AnalyzedItem> get items => _canvas.items;

  /// Current review notes.
  List<ReviewNote> get notes => _canvas.notes;

  /// Index into [pages] of the page currently shown.
  int get currentPageIndex => _canvas.currentPageIndex;

  /// Absolute (1-indexed) page number currently shown.
  int get currentPageNumber => _canvas.currentPageNumber;

  /// Index into [items] of the item being re-selected, or -1 (Req 8.6).
  int get editingIndex => _canvas.editingIndex;

  /// Whether a re-select session is active.
  bool get isEditing => _canvas.isEditing;

  /// Current zoom factor (Req 8.9).
  double get zoom => _canvas.zoom;

  /// Current pan offset; never mutates box coordinates (Req 8.8).
  Offset get pan => _canvas.panOffset;

  /// Painter repaint key (see [ReviewCanvasController.revision]).
  int get revision => _canvas.revision;

  /// An immutable snapshot of the whole session (the design's `ReviewState`).
  ReviewState get state => ReviewState(
        jobId: _jobId,
        pages: _canvas.pages,
        items: _canvas.items,
        notes: _canvas.notes,
        currentPageIndex: _canvas.currentPageIndex,
        editingIndex: _canvas.editingIndex,
        zoom: _canvas.zoom,
        pan: _canvas.panOffset,
        source: _source,
        answerKeyCount: _answerKeyCount,
        methodUsed: _methodUsed,
      );

  // ---- Loading a session (reused by both tools, Req 6.2) -----------------

  /// Loads a Smart Auto Crop review session from a `POST /api/analyze` response
  /// (Req 6.2): captures `jobId` and `answerKeyCount`, and populates the canvas
  /// with the returned page previews, detected items, and review notes. Resets
  /// the view to the first page. The actual analyze HTTP call, opening the
  /// canvas, and answer-sheet messaging are wired in task 12.5.
  void loadFromAnalyze(AnalyzeResponse response) {
    _jobId = response.jobId;
    _answerKeyCount = response.answerKeyCount;
    _methodUsed = response.methodUsed;
    _source = ReviewSource.smartAutoCrop;
    _clearFinalizeState();
    _canvas.load(
      pages: response.pages,
      items: response.items,
      notes: response.notes,
    );
    notifyListeners();
  }

  /// Loads a Manual Crop review session from a `POST /api/prepare-manual`
  /// response (Req 7.2): captures `jobId`, starts with an EMPTY item list and no
  /// notes, and clears the answer-key count (manual crop detects no answer key).
  /// The prepare-manual HTTP call and canvas opening are wired in task 13.1.
  void loadFromManual(AnalyzeResponse response) {
    _jobId = response.jobId;
    _answerKeyCount = null;
    _methodUsed = null;
    _source = ReviewSource.manualCrop;
    _clearFinalizeState();
    _canvas.load(
      pages: response.pages,
      items: const <AnalyzedItem>[],
      notes: const <ReviewNote>[],
    );
    notifyListeners();
  }

  /// Clears the session back to [ReviewState.empty] (e.g. when reopening a tool
  /// or after a finalize). Does not change [source].
  void reset() {
    _jobId = '';
    _answerKeyCount = null;
    _methodUsed = null;
    _clearFinalizeState();
    _canvas.load(pages: const <PageInfo>[]);
    notifyListeners();
  }

  /// Clears the finalize run state (result/error/in-flight flag). Called on
  /// every (re)load and reset so a stale result never offers downloads for a
  /// different session.
  void _clearFinalizeState() {
    _finalizing = false;
    _finalizeError = null;
    _finalizeResult = null;
  }

  // ---- Canvas operation forwarding (page nav / zoom / draw kind) ---------
  //
  // Thin pass-throughs so feature screens holding a [ReviewController] can drive
  // the canvas without reaching into [canvas]. The canvas widget still talks to
  // [canvas] directly. Each notifies through [_onCanvasChanged].

  /// Navigates to [index], clamped to first..last (Req 8.12).
  void gotoPageIndex(int index) => _canvas.gotoPageIndex(index);

  /// Navigates to the page with absolute number [pageNumber] when present.
  void gotoPageNumber(int pageNumber) => _canvas.gotoPageNumber(pageNumber);

  /// Navigates to the previous page (clamped at the first page).
  void previousPage() => _canvas.previousPage();

  /// Navigates to the next page (clamped at the last page).
  void nextPage() => _canvas.nextPage();

  /// Sets an absolute zoom factor, clamped to 0.25..6.0 (Req 8.9).
  void setZoom(double value) => _canvas.setZoom(value);

  /// Multiplies the current zoom by [factor], then clamps (Req 8.9).
  void zoomBy(double factor) => _canvas.zoomBy(factor);

  /// Resets to fit-width (100%).
  void resetZoom() => _canvas.resetZoom();

  /// Selects whether the next drawn box is a solution (Req 8.13).
  void setDrawAsSolution(bool value) => _canvas.setDrawAsSolution(value);

  /// Sets the explicit number for the next drawn box, or '' to auto-number
  /// (Req 8.13).
  void setPendingNumber(String value) => _canvas.setPendingNumber(value);

  /// Commits a freshly drawn segment (Req 8.4/8.5/8.11/8.13). Routes through the
  /// snap seam ([snapInterceptor]) and the canvas controller's draw logic.
  Future<bool> commitDrawnSegment(QuestionSegment drawn) =>
      _canvas.commitDrawnSegment(drawn);

  /// Removes an entire item from the set (Req 8.7).
  void deleteItem(int itemIndex) => _canvas.deleteItem(itemIndex);

  /// Removes a single segment from an item (Req 8.7).
  void deleteSegment(int itemIndex, int segmentIndex) =>
      _canvas.deleteSegment(itemIndex, segmentIndex);

  /// Reorders a part within its item (web `moveSegment`): the stitch order is
  /// the segment order, so this fixes the order a multi-part item is combined
  /// in. [direction] is `-1` (up) or `+1` (down).
  void moveSegment(int itemIndex, int segmentIndex, int direction) =>
      _canvas.moveSegment(itemIndex, segmentIndex, direction);

  // ---- Per-item alignment + preview (the review "Align parts" + Preview) ---

  /// Sets the client-only alignment override for item [itemIndex] — the review
  /// "Align parts" toggle. `null` restores the engine's per-source default
  /// (align manual items only). Carried into both the per-item preview and the
  /// finalize payload, so the downloaded crop matches the previewed one.
  void setItemAlign(int itemIndex, bool? align) =>
      _canvas.setItemAlign(itemIndex, align);

  /// Sets the manual horizontal or vertical nudge for part [segmentIndex] of item
  /// [itemIndex] (the review "Manual align" controls). Carried into the preview
  /// and the finalize payload so the downloaded crop lines up exactly like the
  /// approved preview.
  void setSegmentOffset(int itemIndex, int segmentIndex, {double? xOffsetPct, double? yOffsetPct}) =>
      _canvas.setSegmentOffset(itemIndex, segmentIndex, xOffsetPct: xOffsetPct, yOffsetPct: yOffsetPct);

  /// Clears every manual nudge on item [itemIndex] back to 0.
  void resetSegmentOffsets(int itemIndex) =>
      _canvas.resetSegmentOffsets(itemIndex);

  /// The manual horizontal nudges (`xOffsetPct` per part) for item [itemIndex], in
  /// segment order. Empty when the index is out of range.
  List<double> offsetsFor(int itemIndex) {
    final List<AnalyzedItem> current = _canvas.items;
    if (itemIndex < 0 || itemIndex >= current.length) {
      return const <double>[];
    }
    return <double>[
      for (final QuestionSegment s in current[itemIndex].segments) s.xOffsetPct,
    ];
  }

  /// The manual vertical nudges (`yOffsetPct` per part) for item [itemIndex], in
  /// segment order. Empty when the index is out of range.
  List<double> yOffsetsFor(int itemIndex) {
    final List<AnalyzedItem> current = _canvas.items;
    if (itemIndex < 0 || itemIndex >= current.length) {
      return const <double>[];
    }
    return <double>[
      for (final QuestionSegment s in current[itemIndex].segments) s.yOffsetPct,
    ];
  }

  /// The current alignment override for item [itemIndex], or null when none is
  /// set / the index is out of range.
  bool? alignFor(int itemIndex) {
    final List<AnalyzedItem> current = _canvas.items;
    if (itemIndex < 0 || itemIndex >= current.length) return null;
    return current[itemIndex].align;
  }

  /// Keeps the preview output config in step with the active tool's output
  /// config so a per-item preview renders at the SAME DPI / padding / format
  /// the finalized download will use (preview == final). Called by the host
  /// when the tool's config changes (and once when the canvas opens).
  void setPreviewOutput({
    int? dpi,
    int? padding,
    String? imageFormat,
    int? jpgQuality,
  }) {
    if (dpi != null) _previewDpi = dpi;
    if (padding != null) _previewPadding = padding;
    if (imageFormat != null) _previewImageFormat = imageFormat;
    if (jpgQuality != null) _previewJpgQuality = jpgQuality;
  }

  /// Renders a standalone preview of item [itemIndex] through the engine's
  /// `POST /api/crop/preview`, reusing the same crop/stitch pipeline the
  /// finalized download runs (so it is a faithful "what you see is what you get"
  /// preview). Returns the image bytes, or null when no engine is bound, the
  /// index is out of range, or the item has no segments. Any per-item alignment
  /// override (the "Align parts" toggle) is honoured. Pass [alignOverride] to
  /// preview a specific alignment without committing it to the item first.
  Future<List<int>?> previewItem(int itemIndex, {bool? alignOverride}) async {
    final ApiClient? client = _apiClient;
    if (client == null) return null;
    final List<AnalyzedItem> current = _canvas.items;
    if (itemIndex < 0 || itemIndex >= current.length) return null;
    final AnalyzedItem it = current[itemIndex];
    if (it.segments.isEmpty) return null;

    final List<int> bytes = await client.cropPreview(
      CropPreviewRequest(
        jobId: _jobId,
        qNum: it.qNum,
        isSolution: it.isSolution,
        segments: it.segments,
        source: it.source,
        align: alignOverride ?? it.align,
        dpi: _previewDpi,
        padding: _previewPadding,
        imageFormat: _previewImageFormat,
        jpgQuality: _previewJpgQuality,
      ),
    );
    return bytes;
  }

  // ---- Additive re-select (Req 8.6) + "Done" cleanup (Req 8.7) -----------

  /// Begins re-selecting item [index] (Req 8.6): jumps to its first page and
  /// enters additive re-select. Subsequent drawn boxes are APPENDED to the item
  /// in draw order (segment order is locked — never re-sorted), the item's
  /// `source` becomes `manual`, its `flagged` clears, and any matching review
  /// note is removed. Implemented by the wrapped canvas controller.
  void startReselectForItem(int index) => _canvas.startEditing(index);

  /// Begins re-selecting the item a [note] refers to (the notes-panel Fix
  /// action, Req 10.4): finds the item by the note's `q_num` + type, navigates
  /// to its page, and enters additive re-select. Returns true when a matching
  /// item was found. The note itself is cleared once the user draws (the canvas
  /// controller drops the matching note on the first appended box).
  bool startReselectForNote(ReviewNote note) {
    final String? qNum = note.qNum;
    if (qNum == null) return false;
    return startReselectByQNum(qNum, isSolution: note.isSolution);
  }

  /// Begins re-selecting the item with the given [qNum] and type, if present
  /// (Req 8.6, 10.4). Returns true when a matching item was found.
  bool startReselectByQNum(String qNum, {bool isSolution = false}) {
    final List<AnalyzedItem> current = _canvas.items;
    final int idx = current.indexWhere(
      (AnalyzedItem it) => it.qNum == qNum && it.isSolution == isSolution,
    );
    if (idx < 0) return false;
    _canvas.startEditing(idx);
    return true;
  }

  /// Ends a re-select session (Req 8.7): an item left with zero segments is
  /// dropped rather than shipping an empty crop. Implemented by the wrapped
  /// canvas controller.
  void doneReselecting() => _canvas.stopEditing();

  // ---- Snap seam (task 12.2) ---------------------------------------------

  /// Whether snap-to-content is on (the Snap toggle, Req 9). Defaults to true,
  /// matching the web canvas where the "Snap to content" checkbox is checked by
  /// default. When off, a freshly drawn box is committed verbatim and no
  /// `POST /api/snap` request is made — manual selection still works exactly as
  /// drawn. The interceptor installed by [attachSnap] reads this live, so
  /// toggling it takes effect on the next drawn box without re-wiring.
  bool get snapEnabled => _snapEnabled;

  /// Turns snap-to-content on/off (Req 9). Notifies listeners so a toggle
  /// control re-renders.
  set snapEnabled(bool value) {
    if (value == _snapEnabled) return;
    _snapEnabled = value;
    notifyListeners();
  }

  /// Toggles snap-to-content (convenience for a checkbox/switch).
  void toggleSnap() => snapEnabled = !_snapEnabled;

  /// Wires snap-to-content (Req 9) using [apiClient]: installs a
  /// [SegmentInterceptor] on the wrapped canvas that, on box-end and while
  /// [snapEnabled] is true, calls `POST /api/snap` with the current [jobId] and
  /// the box's `x_start_pct/x_end_pct/y_start_pct/y_end_pct`, then replaces the
  /// box with the engine's tightened rect (Req 9.1, 9.2). On any error or an
  /// unchanged (echoed-back) response the user's drawn box is kept unchanged so
  /// selection never degrades (Req 9.3, 9.4). The interceptor reads [jobId] and
  /// [snapEnabled] lazily, so loading a new session or flipping the toggle needs
  /// no re-wiring.
  void attachSnap(ApiClient apiClient) {
    snapInterceptor = buildSnapInterceptor(
      apiClient: apiClient,
      jobId: () => _jobId,
      enabled: () => _snapEnabled,
    );
  }

  /// The snap-to-content interceptor applied to a freshly drawn box before it
  /// is committed (Req 9). [attachSnap] sets this to a function that calls
  /// `POST /api/snap` and replaces the box with the tightened rect — falling
  /// back to the drawn box on error/unchanged so selection never degrades
  /// (Req 9.3/9.4). Null (the default) commits drawn boxes verbatim.
  SegmentInterceptor? get snapInterceptor => _canvas.segmentInterceptor;
  set snapInterceptor(SegmentInterceptor? interceptor) =>
      _canvas.segmentInterceptor = interceptor;

  // ---- Finalize + download from review (task 12.6, Req 6.6, 11.1–11.5) ----

  /// Whether a `POST /api/finalize` request is in flight.
  bool get finalizing => _finalizing;

  /// The engine `detail` (or a transport message) from the last finalize
  /// attempt, or null when there is none (Req 6.7-style surfacing for finalize).
  String? get finalizeError => _finalizeError;

  /// The most recent successful finalize result, or null. Drives the
  /// Combined/Questions/Solutions download actions (Req 11.1–11.3). Cleared when
  /// a new session is loaded or a fresh finalize starts.
  CropResponse? get finalizeResult => _finalizeResult;

  /// Prompt shown when Finalize is attempted with no items to crop (Req 7.5).
  /// The engine would reject an empty list with HTTP 400 (`ERR_NO_QUESTIONS`);
  /// guarding here avoids a wasted round-trip and gives clearer guidance.
  static const String errNoItems =
      'Draw at least one crop box before finalizing.';

  /// Builds the finalize item payload from the kept review items (Req 6.6/7.4):
  /// every item carrying at least one segment becomes a [FinalizeItem] with its
  /// type, page-percentage region, and source. Items left with zero segments
  /// are skipped (the same cleanup [doneReselecting] applies, here defensively).
  /// [finalize] combines this with the active tool's output config and calls
  /// `POST /api/finalize`.
  List<FinalizeItem> toFinalizeItems() {
    return <FinalizeItem>[
      for (final AnalyzedItem it in _canvas.items)
        if (it.segments.isNotEmpty)
          FinalizeItem(
            qNum: it.qNum,
            isSolution: it.isSolution,
            segments: it.segments,
            source: it.source,
            align: it.align,
          ),
    ];
  }

  /// Assembles a [FinalizeRequest] from the kept items ([toFinalizeItems]) plus
  /// the active tool's output config. This is a PURE builder (no HTTP);
  /// [finalize] issues the `POST /api/finalize` call and the download.
  /// `answerSheet` defaults to whether an answer key was detected, but the
  /// caller may override it from the tool's Answer-sheet toggle (Req 11.5).
  FinalizeRequest buildFinalizeRequest({
    int dpi = 200,
    int padding = 20,
    String questionPrefix = 'Q',
    String solutionPrefix = 'S',
    int startNumber = 1,
    String imageFormat = 'png',
    int jpgQuality = 90,
    bool? answerSheet,
  }) {
    return FinalizeRequest(
      jobId: _jobId,
      items: toFinalizeItems(),
      dpi: dpi,
      padding: padding,
      questionPrefix: questionPrefix,
      solutionPrefix: solutionPrefix,
      startNumber: startNumber,
      imageFormat: imageFormat,
      jpgQuality: jpgQuality,
      answerSheet: answerSheet ?? finalizeWillIncludeAnswerSheet,
    );
  }

  /// Finalizes the reviewed item set into the downloadable ZIP (Req 6.6).
  ///
  /// Builds a [FinalizeRequest] from the kept auto items plus drawn/re-selected
  /// items (each carrying its type + page-percentage region, via
  /// [buildFinalizeRequest]) together with the active tool's output config, and
  /// issues `POST /api/finalize`. On success the engine's [CropResponse] is
  /// stored as [finalizeResult] so the host can offer the Combined / Questions
  /// / Solutions downloads (Req 11.1–11.3); the configured [questionPrefix] /
  /// [solutionPrefix] are retained so [download] can pass them to
  /// `GET /api/crop/download/{job_id}` (Req 11.4). On an engine error the
  /// `{"detail": ...}` message is surfaced via [finalizeError] and the items are
  /// retained so the user can retry (Req 7.7).
  ///
  /// Blocks (returns false) with the [errNoItems] prompt when there are no items
  /// to crop (Req 7.5). A no-op (returns false) when no engine is bound or a run
  /// is already in flight.
  Future<bool> finalize({
    int dpi = 200,
    int padding = 20,
    String questionPrefix = 'Q',
    String solutionPrefix = 'S',
    int startNumber = 1,
    String imageFormat = 'png',
    int jpgQuality = 90,
    bool? answerSheet,
  }) async {
    final ApiClient? client = _apiClient;
    if (client == null || _finalizing) return false;

    // Guard: nothing to crop (Req 7.5). Block before any request, retain items.
    if (toFinalizeItems().isEmpty) {
      _finalizeError = errNoItems;
      _finalizeResult = null;
      notifyListeners();
      return false;
    }

    _finalizing = true;
    _finalizeError = null;
    _finalizeResult = null;
    // Retain the prefixes the download endpoint needs (Req 11.4).
    _finalizeQuestionPrefix = questionPrefix;
    _finalizeSolutionPrefix = solutionPrefix;
    notifyListeners();

    try {
      final CropResponse response = await client.finalize(
        buildFinalizeRequest(
          dpi: dpi,
          padding: padding,
          questionPrefix: questionPrefix,
          solutionPrefix: solutionPrefix,
          startNumber: startNumber,
          imageFormat: imageFormat,
          jpgQuality: jpgQuality,
          answerSheet: answerSheet,
        ),
      );
      _finalizeResult = response;
      return true;
    } on ApiException catch (e) {
      // Surface the engine detail; items are untouched so the user can retry
      // (Req 7.7).
      _finalizeError = e.detail;
      _finalizeResult = null;
      return false;
    } finally {
      _finalizing = false;
      notifyListeners();
    }
  }

  /// Runs on-demand auto-detection on the cached PDF.
  /// If [pageOnly] is true, runs on the current page only and merges the detected boxes
  /// onto the current page. If false, runs on all pages and replaces all boxes.
  Future<void> runAutoDetect({
    bool pageOnly = true,
    bool useAi = false,
    String markerStyle = 'auto',
  }) async {
    final ApiClient? client = _apiClient;
    if (client == null || _autoDetecting) return;

    _autoDetecting = true;
    notifyListeners();

    try {
      final int? targetPage = pageOnly ? currentPageNumber : null;
      final List<AnalyzedItem> detected = await client.autoDetect(
        jobId: _jobId,
        page: targetPage,
        useAi: useAi,
        markerStyle: markerStyle,
      );

      if (pageOnly) {
        if (targetPage != null) {
          _canvas.replaceItemsForPage(targetPage, detected);
        }
      } else {
        _canvas.load(
          pages: _canvas.pages,
          items: detected,
          notes: _canvas.notes,
        );
      }
    } finally {
      _autoDetecting = false;
      notifyListeners();
    }
  }

  /// Whether [archive] is available to download from the current
  /// [finalizeResult] (Req 11.1–11.3).
  ///
  /// The combined archive is always available once finalize succeeds; the
  /// per-type archives are available only when the engine returned a non-null
  /// `questions_download_url` / `solutions_download_url`.
  bool canDownload(CropArchive archive) {
    final CropResponse? response = _finalizeResult;
    if (response == null || _finalizing) return false;
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
  /// (Req 11.1–11.4, 16). Returns the [DownloadResult], or null when the archive
  /// isn't available or no engine is bound. A failed download surfaces its
  /// message in [finalizeError].
  ///
  /// The download is wired through `GET /api/crop/download/{job_id}` built by
  /// [ApiClient.cropDownloadUri], passing the `kind` of the requested archive
  /// (`combined` / `questions` / `solutions`) plus the prefixes the finalize
  /// used (Req 11.4). The Answer-sheet setting (Req 11.5) was carried on the
  /// upstream `POST /api/finalize` request via `answer_sheet`, which determined
  /// whether the produced archive bundles an answer sheet; the download endpoint
  /// itself takes no `answer_sheet` query.
  Future<DownloadResult?> download(CropArchive archive) async {
    final DownloadService? service = _downloadService;
    final CropResponse? response = _finalizeResult;
    if (service == null || response == null || !canDownload(archive)) {
      return null;
    }

    final Uri downloadUri = service.apiClient.cropDownloadUri(
      response.jobId,
      kind: _kindFor(archive),
      questionPrefix: _finalizeQuestionPrefix,
      solutionPrefix: _finalizeSolutionPrefix,
    );

    try {
      return await service.download(
        engineUrl: downloadUri.toString(),
        suggestedName: _suggestedNameFor(archive),
        acceptedTypeGroups: const <XTypeGroup>[_zipTypeGroup],
      );
    } on DownloadException catch (e) {
      _finalizeError = e.message;
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
        return '$_finalizeQuestionPrefix${_finalizeSolutionPrefix}combined.zip';
      case CropArchive.questions:
        return '$_finalizeQuestionPrefix.zip';
      case CropArchive.solutions:
        return '$_finalizeSolutionPrefix.zip';
    }
  }

  /// Save-As filter restricting crop output to a `.zip` file.
  static const XTypeGroup _zipTypeGroup = XTypeGroup(
    label: 'ZIP archive',
    extensions: <String>['zip'],
    uniformTypeIdentifiers: <String>['public.zip-archive'],
    mimeTypes: <String>['application/zip'],
  );

  // ---- Internals ----------------------------------------------------------

  void _onCanvasChanged() => notifyListeners();

  @override
  void dispose() {
    _canvas.removeListener(_onCanvasChanged);
    if (_ownsCanvas) _canvas.dispose();
    super.dispose();
  }
}
