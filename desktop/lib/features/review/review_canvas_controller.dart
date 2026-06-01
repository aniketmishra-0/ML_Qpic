// Interim state holder for the Review Canvas input layer (Req 8.3–8.13).
//
// This controller owns exactly the mutable state the canvas gestures touch —
// the page being viewed, the boxes (items) on it, the editing/hover state, and
// the zoom/pan view transform — and exposes deterministic operations for every
// gesture the web canvas supports. It is a faithful port of the web canvas
// logic in `static/index.html` (`gotoPage`, `setZoom`, `startEditing`,
// `applyReselect`, `addManualItem`, `removeSegment`, `nextAutoNumber`,
// `findOverlappingItem`), reusing the already-completed pure helpers in
// `box_logic.dart` and `review_hit_test.dart`.
//
// SCOPE / SEAM (task 11.5 vs 12.1): the full `ReviewController` / `ReviewState`
// (task 12.1) — finalize, snap wiring, notes panel, answer-key messaging — is a
// separate task that depends on this one. To avoid pre-empting or conflicting
// with it, this class is a minimal *interim* holder named distinctly. Task 12.1
// can either wrap this (delegating canvas-input operations to it) or fold these
// fields into `ReviewState`; the gesture widget talks only to the small surface
// defined here, so either path is clean.
//
// Engine boundary: there is ZERO engine logic here. Drawing produces page-
// percentage [QuestionSegment]s (the engine's own coordinate contract); snap
// (`POST /api/snap`) and finalize (`POST /api/finalize`) are delegations wired
// by later tasks via [segmentInterceptor] / the 12.x controller — never
// computed in Dart.

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../models/crop.dart';
import 'box_logic.dart';
import 'canvas_geometry.dart';
import 'review_hit_test.dart';

/// Optional async transform applied to a freshly drawn segment before it is
/// committed (the seam where task 12.2 plugs in snap-to-content). Returns the
/// segment to actually store; the default is identity. Implementations MUST
/// fall back to the input segment on any failure so manual selection never
/// degrades (Req 9.3, 9.4) — but that engine call lives in the wiring task,
/// not here.
typedef SegmentInterceptor = Future<QuestionSegment> Function(
  QuestionSegment drawn,
);

/// Holds and mutates the Review-Canvas input state, notifying listeners (and
/// bumping [revision] for the painter's `shouldRepaint`) on every change.
class ReviewCanvasController extends ChangeNotifier {
  ReviewCanvasController({
    this.jobId = '',
    List<PageInfo>? pages,
    List<AnalyzedItem>? items,
    List<ReviewNote>? notes,
    double zoom = kFitWidthZoom,
  })  : _pages = List<PageInfo>.of(pages ?? const <PageInfo>[]),
        _items = List<AnalyzedItem>.of(items ?? const <AnalyzedItem>[]),
        _notes = List<ReviewNote>.of(notes ?? const <ReviewNote>[]),
        _zoom = clampZoom(zoom);

  /// Engine crop/analyze job id (used by snap/finalize in later tasks).
  final String jobId;

  // ---- View / page state -------------------------------------------------

  List<PageInfo> _pages;
  List<AnalyzedItem> _items;
  List<ReviewNote> _notes;
  int _currentPageIndex = 0;
  int _editingIndex = -1;
  int _hoveredItemIndex = -1;
  double _zoom;
  Offset _panOffset = Offset.zero;
  int _revision = 0;

  // ---- Draw-kind / numbering (web `drawKind` / `drawNum`) ----------------

  bool _drawAsSolution = false;
  String _pendingNumber = '';

  /// Optional snap seam (task 12.2). When null, drawn segments are committed
  /// as-is.
  SegmentInterceptor? segmentInterceptor;

  // ---- Read-only views ----------------------------------------------------

  /// All pages in review order (absolute page number + `preview_url`).
  List<PageInfo> get pages => List<PageInfo>.unmodifiable(_pages);

  /// All review items. Only segments on [currentPageNumber] are drawn by the
  /// painter, but items can carry segments across pages (cross-page questions).
  List<AnalyzedItem> get items => List<AnalyzedItem>.unmodifiable(_items);

  /// Current review notes (advisories). Re-selecting/overlap-replacing an item
  /// clears the matching note, mirroring the web "fixed" behaviour.
  List<ReviewNote> get notes => List<ReviewNote>.unmodifiable(_notes);

  /// Index into [pages] of the page currently shown, always within range.
  int get currentPageIndex => _currentPageIndex;

  /// Absolute (1-indexed) page number currently shown, matching `seg.page`.
  int get currentPageNumber =>
      _pages.isNotEmpty ? _pages[_currentPageIndex].page : 1;

  /// The `preview_url` of the current page, or null when there are no pages.
  String? get currentPreviewUrl =>
      _pages.isNotEmpty ? _pages[_currentPageIndex].previewUrl : null;

  /// Index into [items] of the item being re-selected, or -1 when not editing.
  int get editingIndex => _editingIndex;

  /// Whether a re-select session is active.
  bool get isEditing => _editingIndex >= 0;

  /// Index into [items] of the hovered item, or -1 when nothing is hovered.
  int get hoveredItemIndex => _hoveredItemIndex;

  /// Current zoom factor, always within [kZoomMin]..[kZoomMax] (Req 8.9).
  double get zoom => _zoom;

  /// Current pan/scroll translation in widget px (Req 8.8). Never affects a
  /// box's page-percentage coordinates.
  Offset get panOffset => _panOffset;

  /// Monotonic counter bumped on every state change; drives the painter's
  /// `shouldRepaint` (see [ReviewPainter.revision]).
  int get revision => _revision;

  /// Whether the next drawn box is a solution (true) or a question (false).
  bool get drawAsSolution => _drawAsSolution;

  /// The user-entered number for the next drawn box, or '' to auto-number.
  String get pendingNumber => _pendingNumber;

  /// True at the first page (used to disable the "previous" affordance).
  bool get isFirstPage => _currentPageIndex == 0;

  /// True at the last page (used to disable the "next" affordance).
  bool get isLastPage =>
      _pages.isEmpty || _currentPageIndex == _pages.length - 1;

  // ---- Loading a review session ------------------------------------------

  /// Replaces the whole review payload (from `/analyze` or `/prepare-manual`)
  /// and resets the view to the first page. Used by the feature controllers in
  /// later tasks; kept here so the canvas widget has a single entry point.
  void load({
    required List<PageInfo> pages,
    List<AnalyzedItem> items = const <AnalyzedItem>[],
    List<ReviewNote> notes = const <ReviewNote>[],
  }) {
    _pages = List<PageInfo>.of(pages);
    _items = List<AnalyzedItem>.of(items);
    _notes = List<ReviewNote>.of(notes);
    _currentPageIndex = 0;
    _editingIndex = -1;
    _hoveredItemIndex = -1;
    _bump();
  }

  // ---- Page navigation (Req 8.12) ----------------------------------------

  /// Navigates to [index], clamped to the range first..last (Req 8.12). Only
  /// the selected page's preview and its boxes are shown — the painter filters
  /// segments by [currentPageNumber], so changing the index is sufficient.
  /// Verbatim clamp from the web `gotoPage`:
  /// `Math.max(0, Math.min(pages.length - 1, idx))`.
  void gotoPageIndex(int index) {
    if (_pages.isEmpty) return;
    final int clamped = math.max(0, math.min(_pages.length - 1, index));
    if (clamped == _currentPageIndex) return;
    _currentPageIndex = clamped;
    _hoveredItemIndex = -1;
    _bump();
  }

  /// Navigates to the previous page (clamped at the first page).
  void previousPage() => gotoPageIndex(_currentPageIndex - 1);

  /// Navigates to the next page (clamped at the last page).
  void nextPage() => gotoPageIndex(_currentPageIndex + 1);

  /// Navigates to the page with absolute number [pageNumber] when present.
  void gotoPageNumber(int pageNumber) {
    final int idx = _pages.indexWhere((PageInfo p) => p.page == pageNumber);
    if (idx >= 0) gotoPageIndex(idx);
  }

  // ---- Zoom (Req 8.8, 8.9) -----------------------------------------------

  /// Sets an absolute zoom factor, clamped to [kZoomMin]..[kZoomMax] (Req 8.9).
  /// Panning/zooming never mutate any box's percentage coordinates (Req 8.8),
  /// because boxes are stored as percentages and only the view transform
  /// changes here.
  void setZoom(double value) {
    final double next = clampZoom(value);
    if (next == _zoom) return;
    _zoom = next;
    _bump();
  }

  /// Multiplies the current zoom by [factor] (web `zoomStep`), then clamps.
  void zoomBy(double factor) => setZoom(_zoom * factor);

  /// Resets to fit-width (zoom == 1.0 == 100%), web `setZoom(1)`.
  void resetZoom() => setZoom(kFitWidthZoom);

  // ---- Pan (Req 8.8) ------------------------------------------------------

  /// Translates the displayed page by [delta] (widget px), changing ONLY the
  /// pan offset — never a box's page-percentage coordinates (Req 8.8).
  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _panOffset += delta;
    _bump();
  }

  /// Sets an absolute pan offset (widget px). See [panBy] for the invariant.
  void setPan(Offset offset) {
    if (offset == _panOffset) return;
    _panOffset = offset;
    _bump();
  }

  // ---- Draw-kind / numbering ---------------------------------------------

  /// Selects whether the next drawn box is a solution (web `drawKind`).
  void setDrawAsSolution(bool value) {
    if (value == _drawAsSolution) return;
    _drawAsSolution = value;
    _bump();
  }

  /// Sets the explicit number for the next drawn box, or '' to auto-number
  /// (web `drawNum`).
  void setPendingNumber(String value) {
    final String trimmed = value.trim();
    if (trimmed == _pendingNumber) return;
    _pendingNumber = trimmed;
    // No repaint needed for a text-field value, but keep listeners (UI) synced.
    notifyListeners();
  }

  // ---- Hover (Req 8.3) ----------------------------------------------------

  /// Resolves [localPoint] to a box (top-most precedence) and sets the hovered
  /// item so the canvas shows that box's number (Req 8.3). Passing null clears
  /// the hover (pointer left the canvas).
  void updateHover(Offset? localPoint, CanvasGeometry geometry) {
    final int next = localPoint == null
        ? -1
        : (hitTest(localPoint, geometry)?.itemIndex ?? -1);
    if (next == _hoveredItemIndex) return;
    _hoveredItemIndex = next;
    _bump();
  }

  /// The question/solution number label for the hovered box, or null when
  /// nothing is hovered. Mirrors the web hover tooltip content (Req 8.3).
  String? get hoveredLabel {
    if (_hoveredItemIndex < 0 || _hoveredItemIndex >= _items.length) {
      return null;
    }
    return _items[_hoveredItemIndex].qNum;
  }

  // ---- Hit-test (Req 8.10) -----------------------------------------------

  /// Resolves [localPoint] to exactly one box via deterministic top-most
  /// precedence, or null (Req 8.10). Delegates to the pure [hitTestTopMost]
  /// so the gesture layer and the single-resolution tests share one source of
  /// truth.
  BoxHit? hitTest(Offset localPoint, CanvasGeometry geometry) {
    return hitTestTopMost(
      items: _items,
      pageNumber: currentPageNumber,
      geometry: geometry,
      localPoint: localPoint,
    );
  }

  // ---- Re-select (Req 8.6) -----------------------------------------------

  /// Begins re-selecting item [index] (web `startEditing`): marks it the
  /// editing target and jumps to the page its first segment lives on so the
  /// user can immediately draw (Req 8.6, and the Fix-action target of 10.4).
  /// Subsequent drawn boxes are APPENDED to this item (additive re-select).
  void startEditing(int index) {
    if (index < 0 || index >= _items.length) return;
    _editingIndex = index;
    final AnalyzedItem it = _items[index];
    if (it.segments.isNotEmpty) {
      final int startPage =
          it.segments.map((QuestionSegment s) => s.page).reduce(math.min);
      gotoPageNumber(startPage);
    }
    _bump();
  }

  /// Ends a re-select session (web `stopEditing`): an item left with zero
  /// segments is dropped rather than shipping an empty crop (Req 8.7 cleanup).
  void stopEditing() {
    final int idx = _editingIndex;
    if (idx >= 0 && idx < _items.length && _items[idx].segments.isEmpty) {
      _items.removeAt(idx);
    }
    _editingIndex = -1;
    _bump();
  }

  // ---- Commit a drawn box (Req 8.4, 8.5, 8.6, 8.11, 8.13) ----------------

  /// Commits a freshly drawn [drawn] segment (already clamped to 0–100 by
  /// [CanvasGeometry.screenToPct], Req 8.4). Applies the snap seam if set, then
  /// routes the result:
  ///
  ///   * discards it when smaller than 1.5% of page width/height (Req 8.5);
  ///   * appends it to the editing item when a re-select is active (Req 8.6);
  ///   * otherwise adds a new item, replacing an overlapping same-type box at
  ///     IoU ≥ 0.6 instead of duplicating (Req 8.11), and auto-numbering as the
  ///     max same-type number + 1 when no explicit number is set (Req 8.13).
  ///
  /// Returns true when a box was created/updated, false when the drag was
  /// discarded as too small.
  Future<bool> commitDrawnSegment(QuestionSegment drawn) async {
    QuestionSegment seg = drawn;
    final SegmentInterceptor? intercept = segmentInterceptor;
    if (intercept != null) {
      seg = await intercept(drawn);
    }
    return commitSegmentSync(seg);
  }

  /// Synchronous core of [commitDrawnSegment] (no snap seam). Exposed for the
  /// gesture layer and tests; returns false when the box is too small (Req 8.5).
  bool commitSegmentSync(QuestionSegment seg) {
    // Req 8.5 — discard a drag below 1.5% of page width OR height.
    if (isDragTooSmall(seg)) return false;

    if (_editingIndex >= 0) {
      _appendToEditingItem(seg);
    } else {
      _addManualItem(seg);
    }
    return true;
  }

  /// Appends [seg] to the item being re-selected (web `applyReselect`).
  ///
  /// Re-select is ADDITIVE: every drawn box is appended in draw order (the web
  /// `manualOrder` lock, always set by `startEditing`, means appended parts are
  /// never re-sorted). The item becomes a manual fix — `source = manual`, the
  /// flag clears — and any matching review note is removed (Req 8.6, 10.4).
  void _appendToEditingItem(QuestionSegment seg) {
    final int idx = _editingIndex;
    if (idx < 0 || idx >= _items.length) return;
    final AnalyzedItem it = _items[idx];
    final List<QuestionSegment> nextSegments =
        List<QuestionSegment>.of(it.segments)..add(seg);
    _items[idx] = _asManual(it, nextSegments);
    _clearNoteFor(it.qNum, it.isSolution);
    _bump();
  }

  /// Adds a new manually drawn item (web `addManualItem`), or replaces an
  /// overlapping same-type item at IoU ≥ 0.6 — preserving its number unless an
  /// explicit number was entered (Req 8.11, 8.13).
  void _addManualItem(QuestionSegment seg) {
    final bool isSolution = _drawAsSolution;
    final String numInput = _pendingNumber;

    final int overlapIdx = findOverlappingItem(seg, isSolution, _items);
    if (overlapIdx >= 0) {
      final AnalyzedItem it = _items[overlapIdx];
      final String number = numInput.isNotEmpty ? numInput : it.qNum;
      _items[overlapIdx] = AnalyzedItem(
        qNum: number,
        isSolution: isSolution,
        segments: <QuestionSegment>[seg],
        source: 'manual',
        flagged: false,
        flagReason: null,
      );
      _pendingNumber = '';
      _clearNoteFor(number, isSolution);
      _bump();
      return;
    }

    final String number =
        numInput.isNotEmpty ? numInput : nextAutoNumber(isSolution, _items);
    _items.add(
      AnalyzedItem(
        qNum: number,
        isSolution: isSolution,
        segments: <QuestionSegment>[seg],
        source: 'manual',
        flagged: false,
        flagReason: null,
      ),
    );
    _pendingNumber = '';
    _bump();
  }

  // ---- Delete (Req 8.7) ---------------------------------------------------

  /// Removes a single segment from an item (the per-box ✕ affordance, web
  /// `removeSegment`) — Req 8.7. The item itself is kept; an item left empty is
  /// dropped on [stopEditing].
  void deleteSegment(int itemIndex, int segmentIndex) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final AnalyzedItem it = _items[itemIndex];
    if (segmentIndex < 0 || segmentIndex >= it.segments.length) return;
    final List<QuestionSegment> nextSegments =
        List<QuestionSegment>.of(it.segments)..removeAt(segmentIndex);
    _items[itemIndex] = AnalyzedItem(
      qNum: it.qNum,
      isSolution: it.isSolution,
      segments: nextSegments,
      source: it.source,
      flagged: it.flagged,
      flagReason: it.flagReason,
    );
    _bump();
  }

  /// Removes an entire item from the set (Req 8.7). Adjusts [editingIndex] so a
  /// removal below the editing target keeps pointing at the same item.
  void deleteItem(int itemIndex) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    _items.removeAt(itemIndex);
    if (_editingIndex == itemIndex) {
      _editingIndex = -1;
    } else if (_editingIndex > itemIndex) {
      _editingIndex -= 1;
    }
    if (_hoveredItemIndex == itemIndex) {
      _hoveredItemIndex = -1;
    } else if (_hoveredItemIndex > itemIndex) {
      _hoveredItemIndex -= 1;
    }
    _bump();
  }

  // ---- Handle resize / move (Req 8.6) ------------------------------------

  /// Replaces the coordinates of segment ([itemIndex], [segmentIndex]) during a
  /// handle drag (web `updateBoxDragTo`). [seg] is expected pre-clamped to
  /// 0–100 (the gesture layer uses `clampPct`). Bumps the revision so the
  /// painter re-renders the moving box live.
  void updateSegmentRect(int itemIndex, int segmentIndex, QuestionSegment seg) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final AnalyzedItem it = _items[itemIndex];
    if (segmentIndex < 0 || segmentIndex >= it.segments.length) return;
    final List<QuestionSegment> next = List<QuestionSegment>.of(it.segments);
    next[segmentIndex] = seg;
    _items[itemIndex] = AnalyzedItem(
      qNum: it.qNum,
      isSolution: it.isSolution,
      segments: next,
      source: it.source,
      flagged: it.flagged,
      flagReason: it.flagReason,
    );
    _bump();
  }

  /// Finalizes a hand-adjusted box (web `endBoxDrag`): the item becomes a manual
  /// fix — `source = manual`, flag cleared — and any matching note is dropped.
  void finishSegmentEdit(int itemIndex) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final AnalyzedItem it = _items[itemIndex];
    _items[itemIndex] = _asManual(it, List<QuestionSegment>.of(it.segments));
    _clearNoteFor(it.qNum, it.isSolution);
    _bump();
  }

  // ---- Internal helpers ---------------------------------------------------

  /// Returns a copy of [it] marked as a manual fix with [segments].
  AnalyzedItem _asManual(AnalyzedItem it, List<QuestionSegment> segments) {
    return AnalyzedItem(
      qNum: it.qNum,
      isSolution: it.isSolution,
      segments: segments,
      source: 'manual',
      flagged: false,
      flagReason: null,
    );
  }

  /// Drops any review note that pointed at the (qNum, type) just fixed, exactly
  /// like the web filter in `applyReselect` / `addManualItem`.
  void _clearNoteFor(String qNum, bool isSolution) {
    _notes.removeWhere(
      (ReviewNote nt) => nt.qNum == qNum && nt.isSolution == isSolution,
    );
  }

  void _bump() {
    _revision++;
    notifyListeners();
  }
}
