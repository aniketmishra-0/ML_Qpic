// Rendering for the Review Canvas (Req 1.5, 6.3, 8.2, 8.3).
//
// This is the painter half of the high-risk Review Canvas. It reproduces the
// web canvas (`static/index.html` `drawExistingBoxes`/`.sel-box`) with a
// `CustomPainter`, while the gesture/hit-test half and the `ReviewController`
// wiring land in later tasks (8.x gestures, 12.1 controller). The painter is
// deliberately stateless: it takes an immutable snapshot of what to draw and
// renders it, so panning, zooming, hovering, and editing only require a new
// snapshot + repaint.
//
// Engine boundary (Req 1.5, 6.3): the page preview is a SERVER-RENDERED PNG.
// The bytes come from the engine `preview_url` and are decoded to a `ui.Image`
// elsewhere (the widget layer / controller); this painter never rasterizes a
// PDF in Dart — it only blits the already-decoded [pageImage]. If the image is
// not yet available the page area is left empty and only the overlays draw.
//
// Box styling mirrors the web rules exactly:
//   * `.existing-box` is a DASHED OUTLINE with NO FILL — translucent fills
//     stack into an opaque mass where many boxes overlap (e.g. an answer-key
//     region) and hide the page; borders keep every box's extent visible.
//   * Color encodes state: success (question/solution), warn (flagged), and
//     the brand accent (the item being re-selected), read from [QpicPalette].
//   * `.sel-box` (the in-progress drag) is the one filled rectangle — a 2px
//     brand border over a 16%-opacity brand fill.
//   * The item being re-selected gets eight resize handles plus a per-box
//     delete affordance, matching `.box-handle` and `.box-del`.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import '../../models/crop.dart';
import 'canvas_geometry.dart';

/// Dash and gap lengths (screen px) for the dashed `.existing-box` outline.
const double _kDashLength = 4.0;
const double _kDashGap = 3.0;

/// Corner radius (screen px) for box outlines, matching the web `border-radius: 3px`.
const double _kBoxRadius = 3.0;

/// Diameter (screen px) of a resize handle, matching the web `.box-handle`
/// (15px). Handles are sized in SCREEN space so they stay grabbable at any zoom.
const double _kHandleSize = 15.0;

/// Diameter (screen px) of the per-box delete affordance, matching `.box-del`.
const double _kDeleteSize = 18.0;

/// The eight resize-handle positions on the active box, in web order
/// (corners first, then edge midpoints).
enum HandlePosition { nw, ne, sw, se, n, s, w, e }

/// Paints the Review Canvas: the server-rendered page preview plus the
/// Detection_Box overlays, the in-progress selection, and — on the item being
/// re-selected — resize handles and a delete affordance.
///
/// The painter is a pure function of its inputs. [revision] is a monotonically
/// increasing counter owned by the `ReviewController`; bumping it (on pan,
/// zoom, hover, edit, item change, …) is what drives [shouldRepaint], so the
/// canvas repaints efficiently without the painter having to deep-compare
/// every field.
class ReviewPainter extends CustomPainter {
  ReviewPainter({
    required this.geometry,
    required this.palette,
    required this.items,
    required this.pageNumber,
    required this.revision,
    required this.selectedIndices,
    this.pageImage,
    this.editingIndex = -1,
    this.hoveredIndex = -1,
    this.selection,
    this.questionPrefix = 'Q',
    this.solutionPrefix = 'S',
  });

  /// Coordinate transforms (page-percent ⇄ screen px) for the current view.
  final CanvasGeometry geometry;

  /// Theme colors used for outlines, labels, and the selection fill.
  final QpicPalette palette;

  /// All review items; only segments whose `page == pageNumber` are drawn.
  final List<AnalyzedItem> items;

  /// Absolute (1-indexed) page number currently shown; matches `seg.page`.
  final int pageNumber;

  /// The already-decoded server-rendered PNG preview for [pageNumber], or null
  /// while it is still loading. NEVER produced by Dart PDF rasterization
  /// (Req 1.5, 6.3) — it is decoded from the engine `preview_url`.
  final ui.Image? pageImage;

  /// Index into [items] of the item being re-selected, or -1 when not editing.
  /// The editing item is drawn with the brand accent and gains handles + a
  /// delete affordance.
  final int editingIndex;

  /// Index into [items] of the hovered item, or -1. Reserved for hover
  /// emphasis; the hovered item's number label is always shown like the rest.
  final int hoveredIndex;

  /// All selected item indices for merging.
  final List<int> selectedIndices;

  /// The in-progress drag rectangle in page-percent space, or null when no
  /// drag is active. Rendered as the filled `.sel-box`.
  final QuestionSegment? selection;

  /// Label prefixes for question / solution items (web `reviewQPrefix` /
  /// `reviewSPrefix`). Defaults match the web defaults.
  final String questionPrefix;
  final String solutionPrefix;

  /// Controller-owned repaint key. See [shouldRepaint].
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    _paintPagePreview(canvas);
    _paintBoxes(canvas);
    _paintSelection(canvas);
  }

  // ---- Page preview (server-rendered PNG, never a Dart-rasterized PDF) ----

  void _paintPagePreview(Canvas canvas) {
    final ui.Image? image = pageImage;
    if (image == null) return;

    final Size display = geometry.pageDisplaySize;
    if (display.width <= 0 || display.height <= 0) return;

    final Rect src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final Rect dst = Rect.fromLTWH(
      geometry.panOffset.dx,
      geometry.panOffset.dy,
      display.width,
      display.height,
    );
    final Paint paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(image, src, dst, paint);
  }

  // ---- Detection_Box overlays (dashed outline only, no fill) --------------

  void _paintBoxes(Canvas canvas) {
    for (int itemIdx = 0; itemIdx < items.length; itemIdx++) {
      final AnalyzedItem item = items[itemIdx];
      final bool isEditing = itemIdx == editingIndex;
      final bool isSelected = selectedIndices.contains(itemIdx);
      final bool multiSegment = item.segments.length > 1;

      for (int segIdx = 0; segIdx < item.segments.length; segIdx++) {
        final QuestionSegment seg = item.segments[segIdx];
        if (seg.page != pageNumber) continue;

        final Rect rect = geometry.segToScreenRect(seg);
        final Color color = _outlineColor(item, isEditing, isSelected);

        if (isEditing) {
          // `.existing-box.editing` — a SOLID 2px brand outline.
          final Paint stroke = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = color;
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(_kBoxRadius)),
            stroke,
          );
        } else if (isSelected) {
          // SOLID 2px brandBlue outline + subtle brandBlue fill.
          final Paint fill = Paint()
            ..style = PaintingStyle.fill
            ..color = palette.brandBlue.withValues(alpha: 0.08);
          final Paint stroke = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = color;
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(_kBoxRadius)),
            fill,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(_kBoxRadius)),
            stroke,
          );
        } else {
          // `.existing-box` / `.existing-box.flagged` — a 1.5px DASHED outline.
          _drawDashedRRect(
            canvas,
            RRect.fromRectAndRadius(rect, const Radius.circular(_kBoxRadius)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = color,
          );
        }

        // Per-box number label (Req 8.3). Multi-segment items get a part
        // letter (a, b, c…) in draw order, matching the web `segLetter`.
        final String label = _label(item, segIdx, multiSegment);
        _drawTag(
            canvas, rect, label, color, isEditing || isSelected, item.flagged);

        // The item being re-selected gets handles + a delete affordance.
        if (isEditing) {
          _drawHandles(canvas, rect);
          _drawDeleteAffordance(canvas, rect);
        }
      }
    }
  }

  /// Outline/label color for an item, by state (Req 8.2):
  /// being re-selected → brand; selected → brandBlue; flagged → warn; otherwise → success.
  Color _outlineColor(AnalyzedItem item, bool isEditing, bool isSelected) {
    if (isEditing) return palette.boxEditing;
    if (isSelected) return palette.brandBlue;
    if (item.flagged) return palette.boxFlagged;
    return palette.boxOutline;
  }

  /// Builds a box's label: `<prefix><q_num>` plus a part letter for
  /// multi-segment items, exactly like the web `drawExistingBoxes`.
  String _label(AnalyzedItem item, int segIdx, bool multiSegment) {
    final String base =
        (item.isSolution ? solutionPrefix : questionPrefix) + item.qNum;
    if (!multiSegment) return base;
    final String segLetter = String.fromCharCode(97 + segIdx);
    return base + segLetter;
  }

  /// Draws the small filled "tag" with the number label at the box's top-left
  /// corner (web `.existing-box .tag`).
  void _drawTag(
    Canvas canvas,
    Rect rect,
    String label,
    Color color,
    bool isEditing,
    bool flagged,
  ) {
    // Flagged tags use dark text on the warn fill (web `#2a1700`); all others
    // use white, matching the web `.tag` rules.
    final Color textColor =
        (flagged && !isEditing) ? const Color(0xFF2A1700) : Colors.white;

    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const double padX = 6.0;
    const double padY = 1.0;
    final double tagW = tp.width + padX * 2;
    final double tagH = tp.height + padY * 2;

    // Anchored to the box's top-left corner (web `top: -1px; left: -1px`).
    final Rect tagRect = Rect.fromLTWH(rect.left, rect.top, tagW, tagH);
    final RRect tagRRect = RRect.fromRectAndCorners(
      tagRect,
      topLeft: const Radius.circular(4),
      bottomRight: const Radius.circular(6),
    );
    canvas.drawRRect(tagRRect, Paint()..color = color);
    tp.paint(canvas, Offset(tagRect.left + padX, tagRect.top + padY));
  }

  // ---- In-progress selection (the one filled rectangle) -------------------

  void _paintSelection(Canvas canvas) {
    final QuestionSegment? sel = selection;
    if (sel == null) return;

    final Rect rect = geometry.segToScreenRect(sel);
    // `.sel-box` — brand fill at 16% over the page, plus a 2px brand border.
    canvas.drawRect(rect, Paint()..color = palette.selectionFill);
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = palette.brand,
    );
  }

  // ---- Resize handles + delete affordance on the active item --------------

  void _drawHandles(Canvas canvas, Rect rect) {
    final Paint fill = Paint()..color = palette.brand;
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white;
    const double r = _kHandleSize / 2;

    for (final HandlePosition pos in HandlePosition.values) {
      final Offset center = handleCenter(rect, pos);
      canvas.drawCircle(center, r, fill);
      canvas.drawCircle(center, r, border);
    }
  }

  void _drawDeleteAffordance(Canvas canvas, Rect rect) {
    final Offset center = deleteAffordanceCenter(rect);
    const double r = _kDeleteSize / 2;

    canvas.drawCircle(center, r, Paint()..color = palette.warn);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = Colors.white,
    );

    final TextPainter tp = TextPainter(
      text: const TextSpan(
        text: '\u2715', // ✕
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  // ---- Public hit-test geometry (shared with the gesture layer, task 12.1) -

  /// Screen-space center of resize handle [pos] for the box [rect]. Exposed so
  /// the gesture layer can hit-test handles against the same geometry the
  /// painter draws.
  static Offset handleCenter(Rect rect, HandlePosition pos) {
    switch (pos) {
      case HandlePosition.nw:
        return rect.topLeft;
      case HandlePosition.ne:
        return rect.topRight;
      case HandlePosition.sw:
        return rect.bottomLeft;
      case HandlePosition.se:
        return rect.bottomRight;
      case HandlePosition.n:
        return Offset(rect.center.dx, rect.top);
      case HandlePosition.s:
        return Offset(rect.center.dx, rect.bottom);
      case HandlePosition.w:
        return Offset(rect.left, rect.center.dy);
      case HandlePosition.e:
        return Offset(rect.right, rect.center.dy);
    }
  }

  /// Screen-space hit rectangle for resize handle [pos] for the box [rect].
  static Rect handleHitRect(Rect rect, HandlePosition pos) {
    return Rect.fromCircle(
      center: handleCenter(rect, pos),
      radius: _kHandleSize / 2,
    );
  }

  /// Screen-space center of the per-box delete affordance for [rect]. Sits
  /// just outside the top-right corner so it clears the resize handles (web
  /// `.box-del` `translate(50%, -110%)`).
  static Offset deleteAffordanceCenter(Rect rect) {
    return Offset(rect.right, rect.top - _kDeleteSize * 0.6);
  }

  /// Screen-space hit rectangle for the per-box delete affordance for [rect].
  static Rect deleteAffordanceHitRect(Rect rect) {
    return Rect.fromCircle(
      center: deleteAffordanceCenter(rect),
      radius: _kDeleteSize / 2,
    );
  }

  // ---- Dashed-rect helper -------------------------------------------------

  /// Strokes [rrect] as a dashed outline using [paint]. Walks the rounded-rect
  /// perimeter with [ui.PathMetric] so dashes follow the corners cleanly.
  void _drawDashedRRect(Canvas canvas, RRect rrect, Paint paint) {
    final Path source = Path()..addRRect(rrect);
    final Path dashed = Path();
    for (final ui.PathMetric metric in source.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + _kDashLength, metric.length);
        dashed.addPath(metric.extractPath(distance, end), Offset.zero);
        distance += _kDashLength + _kDashGap;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(covariant ReviewPainter oldDelegate) {
    // Primary key: the controller-owned revision counter. The remaining checks
    // guard against a repaint being missed if a field changes without the
    // revision being bumped (e.g. a fresh painter built with the same revision
    // but a different decoded image).
    return revision != oldDelegate.revision ||
        pageNumber != oldDelegate.pageNumber ||
        editingIndex != oldDelegate.editingIndex ||
        hoveredIndex != oldDelegate.hoveredIndex ||
        !listEquals(selectedIndices, oldDelegate.selectedIndices) ||
        !identical(pageImage, oldDelegate.pageImage) ||
        !identical(selection, oldDelegate.selection) ||
        !identical(items, oldDelegate.items) ||
        !identical(palette, oldDelegate.palette) ||
        geometry.zoom != oldDelegate.geometry.zoom ||
        geometry.panOffset != oldDelegate.geometry.panOffset ||
        geometry.pageDisplaySize != oldDelegate.geometry.pageDisplaySize;
  }
}
