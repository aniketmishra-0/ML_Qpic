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
//   * Snap (task 12.2): [snapInterceptor] forwards to the canvas controller's
//     segment interceptor; the actual `POST /api/snap` call lives in 12.2.
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

import 'package:flutter/foundation.dart';

import '../../models/analyze.dart';
import '../../models/crop.dart';
import 'canvas_geometry.dart' show kFitWidthZoom;
import 'review_canvas_controller.dart';

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
      other.answerKeyCount == answerKeyCount;

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
      );

  @override
  String toString() =>
      'ReviewState(jobId: $jobId, source: $source, pages: ${pages.length}, '
      'items: ${items.length}, notes: ${notes.length}, '
      'currentPageIndex: $currentPageIndex, editingIndex: $editingIndex, '
      'zoom: $zoom, pan: $pan, answerKeyCount: $answerKeyCount)';
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
  ReviewController({ReviewCanvasController? canvas, bool ownsCanvas = false})
      : _canvas = canvas ?? ReviewCanvasController(),
        _ownsCanvas = canvas == null || ownsCanvas {
    _canvas.addListener(_onCanvasChanged);
  }

  /// The wrapped canvas-input controller (task 11.5). The `ReviewCanvas` widget
  /// binds to this; feature screens can also drive canvas operations through it
  /// or through the forwarding helpers on this controller.
  final ReviewCanvasController _canvas;
  final bool _ownsCanvas;

  String _jobId = '';
  int? _answerKeyCount;
  ReviewSource _source = ReviewSource.smartAutoCrop;

  /// The wrapped canvas-input controller.
  ReviewCanvasController get canvas => _canvas;

  // ---- Session identity ---------------------------------------------------

  /// Engine crop/analyze job id used by snap (12.2) and finalize (12.6).
  String get jobId => _jobId;

  /// Answers parsed from the paper's answer key (Smart Auto Crop), or null for
  /// Manual Crop. See [ReviewState.answerKeyCount].
  int? get answerKeyCount => _answerKeyCount;

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
    _source = ReviewSource.smartAutoCrop;
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
    _source = ReviewSource.manualCrop;
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
    _canvas.load(pages: const <PageInfo>[]);
    notifyListeners();
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

  /// The snap-to-content interceptor applied to a freshly drawn box before it
  /// is committed (Req 9). Task 12.2 sets this to a function that calls
  /// `POST /api/snap` and replaces the box with the tightened rect — falling
  /// back to the drawn box on error/unchanged so selection never degrades
  /// (Req 9.3/9.4). Null (the default) commits drawn boxes verbatim.
  SegmentInterceptor? get snapInterceptor => _canvas.segmentInterceptor;
  set snapInterceptor(SegmentInterceptor? interceptor) =>
      _canvas.segmentInterceptor = interceptor;

  // ---- Finalize seam (task 12.6) -----------------------------------------

  /// Builds the finalize item payload from the kept review items (Req 6.6/7.4):
  /// every item carrying at least one segment becomes a [FinalizeItem] with its
  /// type, page-percentage region, and source. Items left with zero segments
  /// are skipped (the same cleanup [doneReselecting] applies, here defensively).
  /// Task 12.6 combines this with the active tool's output config and calls
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
          ),
    ];
  }

  /// Assembles a [FinalizeRequest] from the kept items ([toFinalizeItems]) plus
  /// the active tool's output config. This is a PURE builder (no HTTP); task
  /// 12.6 issues the `POST /api/finalize` call and the download. `answerSheet`
  /// defaults to whether an answer key was detected, but the caller may override
  /// it from the tool's Answer-sheet toggle (Req 11.5).
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

  // ---- Internals ----------------------------------------------------------

  void _onCanvasChanged() => notifyListeners();

  @override
  void dispose() {
    _canvas.removeListener(_onCanvasChanged);
    if (_ownsCanvas) _canvas.dispose();
    super.dispose();
  }
}
