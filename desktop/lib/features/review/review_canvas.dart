// Review Canvas input + hit-testing widget (Req 8.3, 8.4, 8.6, 8.7, 8.8, 8.9,
// 8.10, 8.12).
//
// This is the input half of the high-risk Review Canvas. It layers a
// `MouseRegion` (hover → q-number) and a `GestureDetector` (drag → draw /
// re-select / handle-resize) over the [ReviewPainter] `CustomPainter`, and
// reproduces the web canvas pointer behaviour from `static/index.html`
// (`pointPct`, `startDraw`/`endDraw`, `beginBoxDrag`/`updateBoxDragTo`,
// `gotoPage`, `setZoom`) exactly. All coordinate math goes through
// [CanvasGeometry]; all box mutation goes through [ReviewCanvasController]; the
// deterministic top-most hit-test is [hitTestTopMost] — so this widget holds
// only the transient in-progress-drag state and wiring.
//
// Engine boundary (Req 1.5, 6.3): the page preview is a SERVER-RENDERED PNG
// loaded from the engine `preview_url`; nothing here rasterizes a PDF or
// computes any detection/crop geometry — drawn boxes are page percentages, the
// engine's own contract.
//
// Zoom integration (Req 8.9, 19.4): when a [DocumentZoomScope] is present, the
// canvas registers a [DocumentZoomController] so the shell's Ctrl/Cmd +/-/0
// shortcuts and menu items drive the canvas zoom. Local pinch/scroll zoom is
// pushed back to that controller. Both clamp to 0.25..6.0 identically, so the
// two stay in sync without feedback loops.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme_controller.dart';
import '../../models/crop.dart';
import '../shell/document_zoom_controller.dart';
import '../shell/document_zoom_scope.dart';
import 'canvas_geometry.dart';
import 'review_canvas_controller.dart';
import 'review_hit_test.dart';
import 'review_painter.dart';

/// Resolves an engine `preview_url` to a full, fetchable URL. Defaults to
/// identity; the feature controllers (task 12.x/13.x) supply one that joins the
/// path onto `Base_URL`. Kept injectable so this widget needs no API client and
/// stays testable offline.
typedef PreviewUrlResolver = String Function(String previewUrl);

/// What an in-progress primary-button drag is doing.
enum _DragMode { none, draw, pan, handleResize }

/// Interactive review surface: a server-rendered page preview with
/// Detection_Box overlays the user can draw, re-select, resize, delete, pan,
/// zoom, and page through.
class ReviewCanvas extends StatefulWidget {
  const ReviewCanvas({
    super.key,
    required this.controller,
    this.previewUrlResolver,
    this.questionPrefix = 'Q',
    this.solutionPrefix = 'S',
    this.wheelZoomSensitivity = 0.0015,
  });

  /// Holds the boxes, page, zoom/pan, and editing state. The widget reads it to
  /// paint and calls its mutators on every gesture.
  final ReviewCanvasController controller;

  /// Joins an engine `preview_url` onto the live `Base_URL` (task 12.x). When
  /// null the `preview_url` is used verbatim.
  final PreviewUrlResolver? previewUrlResolver;

  /// Box-label prefixes (web `reviewQPrefix` / `reviewSPrefix`).
  final String questionPrefix;
  final String solutionPrefix;

  /// Trackpad/`Ctrl`+wheel zoom sensitivity (web `Math.exp(-deltaY * 0.0015)`).
  final double wheelZoomSensitivity;

  @override
  State<ReviewCanvas> createState() => _ReviewCanvasState();
}

class _ReviewCanvasState extends State<ReviewCanvas> {
  // ---- In-progress drag state (transient; not in the controller) ---------

  _DragMode _dragMode = _DragMode.none;

  /// The drag's anchor point in page-percent, captured on pan start.
  Offset _drawStartPct = Offset.zero;

  /// The in-progress selection rectangle (page-percent) shown by the painter.
  QuestionSegment? _selection;

  /// Active handle-resize target + starting geometry.
  int _handleItemIndex = -1;
  int _handleSegIndex = -1;
  HandlePosition _handleMode = HandlePosition.se;
  late QuestionSegment _handleStartSeg;
  Offset _handleStartPct = Offset.zero;

  /// Middle-button pan tracking (independent of the primary-button gesture).
  bool _middlePanning = false;
  Offset _middlePanLast = Offset.zero;

  // ---- Page preview image -------------------------------------------------

  ui.Image? _pageImage;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  String? _loadedUrl;

  // ---- Geometry snapshot (rebuilt every layout; read by gestures) --------

  CanvasGeometry _geometry = CanvasGeometry(
    pageDisplaySize: Size.zero,
    zoom: kFitWidthZoom,
  );

  // ---- Shell zoom integration --------------------------------------------

  DocumentZoomController? _zoomController;
  ActiveDocumentZoom? _zoomRegistry;
  bool _syncingZoom = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _maybeLoadPageImage();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachShellZoom();
  }

  @override
  void didUpdateWidget(covariant ReviewCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _loadedUrl = null; // force a reload for the new controller's page
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _detachImageStream();
    if (_zoomController != null) {
      _zoomController!.removeListener(_onShellZoomChanged);
      _zoomRegistry?.unregister(_zoomController!);
      _zoomController!.dispose();
    }
    super.dispose();
  }

  // ---- Shell zoom wiring --------------------------------------------------

  void _attachShellZoom() {
    final ActiveDocumentZoom? registry = DocumentZoomScope.maybeOf(context);
    if (identical(registry, _zoomRegistry)) return;

    if (_zoomController != null) {
      _zoomController!.removeListener(_onShellZoomChanged);
      _zoomRegistry?.unregister(_zoomController!);
      _zoomController!.dispose();
      _zoomController = null;
    }
    _zoomRegistry = registry;
    if (registry == null) return;

    final DocumentZoomController zc =
        DocumentZoomController(zoom: widget.controller.zoom);
    zc.addListener(_onShellZoomChanged);
    registry.register(zc);
    _zoomController = zc;
  }

  /// Shell zoom changed (a +/-/0 shortcut or menu item) → drive the canvas.
  void _onShellZoomChanged() {
    final DocumentZoomController? zc = _zoomController;
    if (zc == null || _syncingZoom) return;
    _syncingZoom = true;
    widget.controller.setZoom(zc.zoom);
    _syncingZoom = false;
  }

  /// Canvas state changed; keep the shell zoom controller and the page image
  /// in sync, then repaint.
  void _onControllerChanged() {
    final DocumentZoomController? zc = _zoomController;
    if (zc != null && !_syncingZoom && zc.zoom != widget.controller.zoom) {
      _syncingZoom = true;
      zc.setZoom(widget.controller.zoom);
      _syncingZoom = false;
    }
    _maybeLoadPageImage();
    if (mounted) setState(() {});
  }

  // ---- Page preview loading (server-rendered PNG; Req 1.5, 6.3) ----------

  void _maybeLoadPageImage() {
    final String? url = widget.controller.currentPreviewUrl;
    if (url == null || url.isEmpty) {
      if (_pageImage != null || _loadedUrl != null) {
        _detachImageStream();
        _pageImage = null;
        _loadedUrl = null;
      }
      return;
    }
    if (url == _loadedUrl) return;
    _loadedUrl = url;

    final String resolved = widget.previewUrlResolver?.call(url) ?? url;
    _detachImageStream();
    final ImageStream stream =
        NetworkImage(resolved).resolve(ImageConfiguration.empty);
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) return;
        setState(() => _pageImage = info.image);
      },
      onError: (Object _, StackTrace? __) {
        if (!mounted) return;
        setState(() => _pageImage = null);
      },
    );
    stream.addListener(listener);
    _imageStream = stream;
    _imageListener = listener;
  }

  void _detachImageStream() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  // ---- Geometry -----------------------------------------------------------

  /// Builds the current view geometry for a viewport of [viewport] size.
  ///
  /// Fit-width (zoom == 1.0) makes the page exactly fill the viewport width
  /// (Req 8.9); the page height follows the page's aspect ratio, taken from the
  /// engine-provided [PageInfo] (`width_pt`/`height_pt`) or, failing that, the
  /// decoded preview's pixel size. Zoom scales that size; pan translates it.
  CanvasGeometry _computeGeometry(Size viewport) {
    final ReviewCanvasController c = widget.controller;
    double aspect = 0;
    if (c.pages.isNotEmpty) {
      final PageInfo page = c.pages[c.currentPageIndex];
      if (page.widthPt > 0) aspect = page.heightPt / page.widthPt;
    }
    if (aspect <= 0 && _pageImage != null && _pageImage!.width > 0) {
      aspect = _pageImage!.height / _pageImage!.width;
    }
    if (aspect <= 0) aspect = math.sqrt2; // A-series fallback

    final double fitWidth = viewport.width > 0 ? viewport.width : 1.0;
    final Size fitSize = Size(fitWidth, fitWidth * aspect);
    return CanvasGeometry.fromFitWidth(
      fitWidthSize: fitSize,
      zoom: c.zoom,
      panOffset: c.panOffset,
    );
  }

  bool get _spacePressed => HardwareKeyboard.instance.logicalKeysPressed
      .contains(LogicalKeyboardKey.space);

  // ---- Hover (Req 8.3) ----------------------------------------------------

  void _onHover(PointerHoverEvent event) {
    widget.controller.updateHover(event.localPosition, _geometry);
  }

  void _onExit(PointerExitEvent event) {
    widget.controller.updateHover(null, _geometry);
  }

  // ---- Scroll / pinch zoom + scroll pan (Req 8.8, 8.9) -------------------

  /// Whether the current primary drag originated from a trackpad pan-zoom event
  /// (two-finger scroll). When true, the GestureDetector pan callbacks treat it
  /// as canvas panning rather than drawing a selection box.
  bool _trackpadPanning = false;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // When a trackpad pan-zoom session is active, PointerPanZoomUpdate already
    // handles the panning — skip the scroll event to avoid double-panning.
    if (_trackpadPanning) return;
    final bool zoomModifier = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (zoomModifier) {
      // Web: trackpad pinch reports as ctrl+wheel → exponential zoom.
      final double factor =
          math.exp(-event.scrollDelta.dy * widget.wheelZoomSensitivity);
      widget.controller.zoomBy(factor);
    } else {
      // Plain wheel scrolls the page (pan only — never mutates pct, Req 8.8).
      widget.controller.panBy(-event.scrollDelta);
    }
  }

  void _onPointerPanZoomStart(PointerPanZoomStartEvent event) {
    // A trackpad two-finger gesture started — mark it so the GestureDetector
    // pan callbacks (which will fire on the same pointer) treat it as panning,
    // not drawing.
    _trackpadPanning = true;
  }

  void _onPointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    // Trackpad two-finger scroll → pan the canvas directly.
    final bool zoomModifier = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (zoomModifier) {
      // Pinch-to-zoom on trackpad.
      widget.controller.zoomBy(event.scale);
    } else {
      widget.controller.panBy(event.panDelta);
    }
  }

  void _onPointerPanZoomEnd(PointerPanZoomEndEvent event) {
    _trackpadPanning = false;
  }

  // ---- Middle-button pan (Req 8.8) ---------------------------------------

  /// Tracks the pointer device kind of the current primary pointer so we can
  /// distinguish a real mouse click-drag (draw) from a trackpad touch-drag
  /// (scroll/pan). On macOS trackpads, two-finger scrolls can arrive as regular
  /// pointer-down + pointer-move when `PointerPanZoom` events are not emitted.
  PointerDeviceKind? _primaryPointerKind;

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kMiddleMouseButton != 0) {
      _middlePanning = true;
      _middlePanLast = event.localPosition;
    }
    // Record the kind for the primary button so _onPanStart can decide
    // whether to draw or pan.
    if (event.buttons & kPrimaryButton != 0) {
      _primaryPointerKind = event.kind;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_middlePanning) return;
    widget.controller.panBy(event.localPosition - _middlePanLast);
    _middlePanLast = event.localPosition;
  }

  void _onPointerUp(PointerUpEvent event) {
    _middlePanning = false;
    _primaryPointerKind = null;
  }

  // ---- Tap: per-box delete affordance (Req 8.7) --------------------------

  void _onTapUp(TapUpDetails details) {
    final ReviewCanvasController c = widget.controller;
    if (!c.isEditing) return;
    final int editIdx = c.editingIndex;
    if (editIdx < 0 || editIdx >= c.items.length) return;
    final AnalyzedItem item = c.items[editIdx];
    final int pageNo = c.currentPageNumber;
    final Offset pos = details.localPosition;

    for (int s = item.segments.length - 1; s >= 0; s--) {
      final QuestionSegment seg = item.segments[s];
      if (seg.page != pageNo) continue;
      final Rect rect = _geometry.segToScreenRect(seg);
      if (ReviewPainter.deleteAffordanceHitRect(rect).contains(pos)) {
        c.deleteSegment(editIdx, s);
        return;
      }
    }
  }

  // ---- Double-tap: enter edit mode on a box (resize/extend/fix) ----------

  void _onDoubleTapDown(TapDownDetails details) {
    final ReviewCanvasController c = widget.controller;
    final Offset pos = details.localPosition;

    // Hit-test to find which box was double-tapped.
    final BoxHit? hit = c.hitTest(pos, _geometry);

    if (hit != null) {
      // A box was double-tapped: enter edit mode for that item (shows resize
      // handles, allows extending/adjusting the box boundaries).
      if (c.editingIndex == hit.itemIndex) {
        // Already editing this item — double-tap again exits edit mode.
        c.stopEditing();
      } else {
        // Stop any current editing, then start editing the tapped box.
        if (c.isEditing) c.stopEditing();
        c.startEditing(hit.itemIndex);
      }
    } else {
      // Double-tapped empty space — exit edit mode if active.
      if (c.isEditing) c.stopEditing();
    }
  }

  // ---- Primary-button drag: draw / re-select / handle resize / pan -------

  void _onPanStart(DragStartDetails details) {
    final ReviewCanvasController c = widget.controller;
    final Offset pos = details.localPosition;

    // Trackpad two-finger scroll: treat as pan, not draw.
    if (_trackpadPanning || _spacePressed) {
      _dragMode = _DragMode.pan;
      return;
    }

    // In re-select, a press on a handle or the delete affordance of the editing
    // item takes precedence over starting a fresh draw.
    if (c.isEditing) {
      final int editIdx = c.editingIndex;
      if (editIdx >= 0 && editIdx < c.items.length) {
        final AnalyzedItem item = c.items[editIdx];
        final int pageNo = c.currentPageNumber;
        for (int s = item.segments.length - 1; s >= 0; s--) {
          final QuestionSegment seg = item.segments[s];
          if (seg.page != pageNo) continue;
          final Rect rect = _geometry.segToScreenRect(seg);
          // Delete affordance: swallow the press so no box is drawn; the actual
          // removal is handled by the tap recognizer (_onTapUp).
          if (ReviewPainter.deleteAffordanceHitRect(rect).contains(pos)) {
            _dragMode = _DragMode.none;
            return;
          }
          for (final HandlePosition hp in HandlePosition.values) {
            if (ReviewPainter.handleHitRect(rect, hp).contains(pos)) {
              _dragMode = _DragMode.handleResize;
              _handleItemIndex = editIdx;
              _handleSegIndex = s;
              _handleMode = hp;
              _handleStartSeg = seg;
              _handleStartPct = _geometry.screenToPct(pos);
              return;
            }
          }
        }
      }
    }

    // Otherwise: draw a new selection (clamped to 0..100 by screenToPct).
    _dragMode = _DragMode.draw;
    _drawStartPct = _geometry.screenToPct(pos);
    setState(() {
      _selection = _segmentFromPctPoints(_drawStartPct, _drawStartPct);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final ReviewCanvasController c = widget.controller;
    switch (_dragMode) {
      case _DragMode.pan:
        c.panBy(details.delta); // pan only — never mutate pct (Req 8.8)
        break;
      case _DragMode.draw:
        final Offset p = _geometry.screenToPct(details.localPosition);
        setState(() {
          _selection = _segmentFromPctPoints(_drawStartPct, p);
        });
        break;
      case _DragMode.handleResize:
        _updateHandleResize(details.localPosition);
        break;
      case _DragMode.none:
        break;
    }
  }

  Future<void> _onPanEnd(DragEndDetails details) async {
    final ReviewCanvasController c = widget.controller;
    final _DragMode mode = _dragMode;
    _dragMode = _DragMode.none;

    switch (mode) {
      case _DragMode.draw:
        final QuestionSegment? seg = _selection;
        setState(() => _selection = null);
        if (seg != null) {
          // The controller discards a too-small drag (<1.5%, Req 8.5), appends
          // to the editing item (Req 8.6) or adds/overlap-replaces an item
          // (Req 8.11, 8.13). Snap (Req 9) plugs in via segmentInterceptor.
          await c.commitDrawnSegment(seg);
        }
        break;
      case _DragMode.handleResize:
        c.finishSegmentEdit(_handleItemIndex);
        _handleItemIndex = -1;
        _handleSegIndex = -1;
        break;
      case _DragMode.pan:
      case _DragMode.none:
        break;
    }
  }

  void _onPanCancel() {
    if (_dragMode == _DragMode.draw && _selection != null) {
      setState(() => _selection = null);
    }
    _dragMode = _DragMode.none;
  }

  /// Applies a handle-resize drag to its target segment (web `updateBoxDragTo`,
  /// resize branch). Each affected edge moves by the pointer delta in percent
  /// and is clamped to 0..100; the rect is re-normalized so end >= start.
  void _updateHandleResize(Offset localPos) {
    final Offset p = _geometry.screenToPct(localPos);
    final double dx = p.dx - _handleStartPct.dx;
    final double dy = p.dy - _handleStartPct.dy;
    final QuestionSegment s = _handleStartSeg;

    double x0 = s.xStartPct, y0 = s.yStartPct, x1 = s.xEndPct, y1 = s.yEndPct;
    final HandlePosition m = _handleMode;
    if (_affectsW(m)) x0 = clampPct(s.xStartPct + dx);
    if (_affectsE(m)) x1 = clampPct(s.xEndPct + dx);
    if (_affectsN(m)) y0 = clampPct(s.yStartPct + dy);
    if (_affectsS(m)) y1 = clampPct(s.yEndPct + dy);

    widget.controller.updateSegmentRect(
      _handleItemIndex,
      _handleSegIndex,
      QuestionSegment(
        page: s.page,
        xStartPct: math.min(x0, x1),
        xEndPct: math.max(x0, x1),
        yStartPct: math.min(y0, y1),
        yEndPct: math.max(y0, y1),
      ),
    );
  }

  static bool _affectsW(HandlePosition p) =>
      p == HandlePosition.nw || p == HandlePosition.sw || p == HandlePosition.w;
  static bool _affectsE(HandlePosition p) =>
      p == HandlePosition.ne || p == HandlePosition.se || p == HandlePosition.e;
  static bool _affectsN(HandlePosition p) =>
      p == HandlePosition.nw || p == HandlePosition.ne || p == HandlePosition.n;
  static bool _affectsS(HandlePosition p) =>
      p == HandlePosition.sw || p == HandlePosition.se || p == HandlePosition.s;

  /// Builds a normalized (end >= start) page-percent segment on the current
  /// page from two pct points (web `endDraw` min/max), Req 8.4.
  QuestionSegment _segmentFromPctPoints(Offset a, Offset b) {
    return QuestionSegment(
      page: widget.controller.currentPageNumber,
      xStartPct: math.min(a.dx, b.dx),
      xEndPct: math.max(a.dx, b.dx),
      yStartPct: math.min(a.dy, b.dy),
      yEndPct: math.max(a.dy, b.dy),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ReviewCanvasController c = widget.controller;
    final QpicPalette palette = Theme.of(context).extension<QpicPalette>() ??
        QpicPalette.dark;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = constraints.biggest;
        _geometry = _computeGeometry(viewport);
        // Keep the controller aware of the viewport size for pan clamping.
        widget.controller.setViewportSize(viewport);

        return Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerPanZoomStart: _onPointerPanZoomStart,
          onPointerPanZoomUpdate: _onPointerPanZoomUpdate,
          onPointerPanZoomEnd: _onPointerPanZoomEnd,
          child: MouseRegion(
            onHover: _onHover,
            onExit: _onExit,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Only allow mouse and touch (for tests) to trigger pan/draw
              // gestures. Trackpad two-finger gestures are handled separately
              // via onPointerSignal (scroll) and onPointerPanZoom (pan/pinch),
              // preventing accidental box selection while scrolling.
              supportedDevices: const <PointerDeviceKind>{
                PointerDeviceKind.mouse,
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
              onTapUp: _onTapUp,
              onDoubleTapDown: _onDoubleTapDown,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              onPanCancel: _onPanCancel,
              child: ClipRect(
                child: CustomPaint(
                  size: viewport,
                  painter: ReviewPainter(
                    geometry: _geometry,
                    palette: palette,
                    items: c.items,
                    pageNumber: c.currentPageNumber,
                    revision: c.revision,
                    pageImage: _pageImage,
                    editingIndex: c.editingIndex,
                    hoveredIndex: c.hoveredItemIndex,
                    selection: _selection,
                    questionPrefix: widget.questionPrefix,
                    solutionPrefix: widget.solutionPrefix,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
