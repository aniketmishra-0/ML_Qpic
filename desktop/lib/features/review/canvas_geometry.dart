// Coordinate transforms for the Review Canvas (Req 8.1, 8.4, 8.6, 8.8, 8.9).
//
// The engine's contract is page-PERCENTAGE coordinates: every QuestionSegment
// carries x_start_pct/x_end_pct/y_start_pct/y_end_pct in 0..100 of the page
// width/height, with end >= start. The canvas keeps boxes in that space and
// converts to/from screen pixels for rendering and pointer input.
//
// There are three coordinate spaces, and this class is the single source of
// truth for moving between them so the painter and the gesture code never
// disagree:
//
//   page-percent (0..100)
//     ⇄  image-content px   (preview natural size × zoom == pageDisplaySize)
//     ⇄  widget/screen px   (image-content px + panOffset)
//
// The math mirrors the web canvas in `static/index.html` exactly:
//   * `pointPct(e)`  — pixel → percent on pointer (clamps the pixel into the
//     image box, so the resulting percent always lands in 0..100).
//   * `placeSel(...)`— percent → CSS `%` over the image-sized frame.
//   * `clamp01(v)`   — `Math.min(100, Math.max(0, v))` (named for 0..1 but in
//     practice clamps a PERCENT to 0..100).
//   * `clampZoom(z)` — `Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z))` with
//     `ZOOM_MIN = 0.25`, `ZOOM_MAX = 6`, fit-width == zoom 1.0.
//
// No engine logic lives here — this is pure geometry shared by the Dart UI.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../../models/crop.dart' show QuestionSegment;

/// Minimum zoom factor (25%), matching the web `ZOOM_MIN`.
const double kZoomMin = 0.25;

/// Maximum zoom factor (600%), matching the web `ZOOM_MAX`.
const double kZoomMax = 6.0;

/// Fit-width baseline: zoom 1.0 means the page exactly fills the available
/// width (web comment: "Zoom: scale the page freely (fit-width = 1.0)").
const double kFitWidthZoom = 1.0;

/// Clamp a zoom factor to the supported range [0.25, 6.0].
///
/// Verbatim port of the web `clampZoom`:
/// `Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z))`.
double clampZoom(double z) => math.min(kZoomMax, math.max(kZoomMin, z));

/// Clamp a page-percentage value to the range [0, 100].
///
/// Verbatim port of the web `clamp01`:
/// `Math.min(100, Math.max(0, v))` (the name says "01" but it operates on a
/// percent, so the bounds are 0..100).
double clampPct(double v) => math.min(100.0, math.max(0.0, v));

/// Bidirectional mapping between the three Review-Canvas coordinate spaces.
///
/// An instance is a snapshot of the current view: the displayed page size
/// (already scaled by [zoom]), the pan/scroll translation, and the zoom
/// factor. It is immutable; produce a new one with [copyWith] when the view
/// changes. Because boxes are stored as page percentages, panning and zooming
/// only change this geometry — never a box's stored coordinates (Req 8.8).
class CanvasGeometry {
  /// Creates a geometry snapshot.
  ///
  /// [pageDisplaySize] is the preview's on-screen size AFTER zoom has been
  /// applied (i.e. natural preview size × zoom). [zoom] is clamped into
  /// [kZoomMin]..[kZoomMax] on construction so a [CanvasGeometry] can never
  /// report an out-of-range zoom (Req 8.9).
  CanvasGeometry({
    required this.pageDisplaySize,
    required double zoom,
    this.panOffset = Offset.zero,
  }) : zoom = clampZoom(zoom);

  /// Builds a geometry from the fit-width natural size and a zoom factor.
  ///
  /// [fitWidthSize] is the page's displayed size at fit-width (zoom == 1.0);
  /// the resulting [pageDisplaySize] is that size scaled by the clamped zoom.
  /// This makes the "fit-width = 100%" relationship explicit (Req 8.9).
  factory CanvasGeometry.fromFitWidth({
    required Size fitWidthSize,
    double zoom = kFitWidthZoom,
    Offset panOffset = Offset.zero,
  }) {
    final double z = clampZoom(zoom);
    return CanvasGeometry(
      pageDisplaySize: Size(fitWidthSize.width * z, fitWidthSize.height * z),
      zoom: z,
      panOffset: panOffset,
    );
  }

  /// Preview size after zoom (image-content px). The fit-width baseline is
  /// this size at [zoom] == 1.0.
  final Size pageDisplaySize;

  /// Scroll/pan translation from image-content px to widget/screen px. Panning
  /// changes only this offset, never any page-percentage coordinate (Req 8.8).
  final Offset panOffset;

  /// Current zoom factor, always within [kZoomMin]..[kZoomMax] (Req 8.9).
  final double zoom;

  /// page-percent → widget/screen px.
  ///
  /// Mirrors the web `placeSel`: a percent maps to `(pct / 100) × imageSize`
  /// over the image-sized frame, then the pan/scroll translation is added to
  /// reach screen space.
  Offset pctToScreen(double xPct, double yPct) {
    final double x = (xPct / 100.0) * pageDisplaySize.width + panOffset.dx;
    final double y = (yPct / 100.0) * pageDisplaySize.height + panOffset.dy;
    return Offset(x, y);
  }

  /// widget/screen px → page-percent, clamped to 0..100 (Req 8.4, 8.6).
  ///
  /// Mirrors the web `pointPct`: the pixel is taken relative to the image box
  /// (remove the pan translation), divided by the image size to get a percent,
  /// and clamped to 0..100 exactly like `clamp01`. A zero-sized axis yields 0
  /// for that axis, matching the web's `rect.width > 0 ? ... : 0` guard.
  Offset screenToPct(Offset local) {
    final double dx = local.dx - panOffset.dx;
    final double dy = local.dy - panOffset.dy;
    final double xPct = pageDisplaySize.width > 0
        ? clampPct((dx / pageDisplaySize.width) * 100.0)
        : 0.0;
    final double yPct = pageDisplaySize.height > 0
        ? clampPct((dy / pageDisplaySize.height) * 100.0)
        : 0.0;
    return Offset(xPct, yPct);
  }

  /// Returns the widget/screen-space rectangle for a segment.
  ///
  /// Segments satisfy end >= start, but [Rect.fromPoints] is used so the
  /// returned rect stays well-formed even for a degenerate or inverted input.
  Rect segToScreenRect(QuestionSegment s) {
    final Offset topLeft = pctToScreen(s.xStartPct, s.yStartPct);
    final Offset bottomRight = pctToScreen(s.xEndPct, s.yEndPct);
    return Rect.fromPoints(topLeft, bottomRight);
  }

  /// Returns a copy with selected fields replaced. Passing [zoom] re-clamps it.
  CanvasGeometry copyWith({
    Size? pageDisplaySize,
    Offset? panOffset,
    double? zoom,
  }) {
    return CanvasGeometry(
      pageDisplaySize: pageDisplaySize ?? this.pageDisplaySize,
      panOffset: panOffset ?? this.panOffset,
      zoom: zoom ?? this.zoom,
    );
  }

  @override
  String toString() => 'CanvasGeometry(pageDisplaySize: $pageDisplaySize, '
      'panOffset: $panOffset, zoom: $zoom)';
}
