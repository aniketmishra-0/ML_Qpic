// Geometry for the Edit tool's clickable span overlays (Req 15.2, 15.3).
//
// The Edit tool renders each page as a SERVER-RENDERED PNG (the engine
// `preview_url`) and overlays each editable text run (`Edit_Span`) as a
// clickable box positioned over that preview. Unlike the Review Canvas — which
// stores boxes in page PERCENTAGES — the engine returns each span's `bbox` in
// PDF POINTS ([x0, y0, x1, y1]) together with the page's `width`/`height` in
// PDF points. This file is the single source of truth for converting a span
// bbox (PDF points) into a display-space rectangle (px), so the overlay always
// lines up with the rendered page at any displayed size.
//
// The math mirrors the web editor (`static/edit.js` `layoutSpans`) exactly. In
// the web code the page element is sized `width*zoom × height*zoom` (points ×
// zoom) and a span is placed with `left = x0 * zoom`, `top = y0 * zoom`, etc.
// Because the displayed page width equals `pageWidthPt * zoom`, that is
// algebraically identical to scaling each point coordinate by
// `displaySize / pageSizePt` — which is what [spanDisplayRect] does, so it
// works for an arbitrary displayed image size (fit-width, zoomed, or natural).
//
// No engine logic lives here — this is pure geometry shared by the Dart UI.

import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import '../../../models/tools.dart'
    show EditPageModel, EditableSpanModel, VectorObjectModel;

/// Minimum on-screen size (px) for a span box, matching the web
/// `Math.max(6, ...)` clamp in `layoutSpans` so a hair-thin run is still a
/// grabbable click target.
const double kMinSpanBoxSize = 6.0;

/// The page's natural size in PDF points (`width`/`height` from the engine).
Size pageSizePt(EditPageModel page) => Size(page.width, page.height);

/// The displayed (px) size of [page] when fit to [availableWidth].
///
/// Reproduces the web "Fit width" baseline (`computeFitWidthZoom`): the page is
/// scaled so its width fills the available width, preserving aspect ratio. A
/// non-positive page width or available width yields [Size.zero] so callers can
/// guard a not-yet-measured layout. The result is the size to pass as
/// `displaySize` to [spanDisplayRect].
Size displaySizeForWidth(EditPageModel page, double availableWidth) {
  final double w = page.width;
  final double h = page.height;
  if (w <= 0 || h <= 0 || availableWidth <= 0) return Size.zero;
  return Size(availableWidth, availableWidth * (h / w));
}

/// Converts a span [bbox] (PDF points, `[x0, y0, x1, y1]`) into a display-space
/// rectangle (px) over a page rendered at [displaySize].
///
/// [pageSize] is the page's natural size in PDF points; each point coordinate
/// is scaled by `displaySize / pageSize` independently on each axis (the
/// preview is rendered at the page's aspect ratio, so the two scales match, but
/// scaling per-axis keeps the mapping correct even if a caller passes a
/// non-proportional [displaySize]).
///
/// The returned rect's width/height are clamped to a minimum of [minSize] (px)
/// like the web overlay, and the origin is clamped to be non-negative. A
/// degenerate or zero [pageSize] yields [Rect.zero].
Rect spanDisplayRect({
  required List<double> bbox,
  required Size pageSize,
  required Size displaySize,
  double minSize = kMinSpanBoxSize,
}) {
  if (pageSize.width <= 0 || pageSize.height <= 0) return Rect.zero;
  if (bbox.length < 4) return Rect.zero;

  final double scaleX = displaySize.width / pageSize.width;
  final double scaleY = displaySize.height / pageSize.height;

  final double x0 = bbox[0];
  final double y0 = bbox[1];
  final double x1 = bbox[2];
  final double y1 = bbox[3];

  // Normalize in case a span ever arrives with inverted corners.
  final double left = math.min(x0, x1) * scaleX;
  final double top = math.min(y0, y1) * scaleY;
  final double rawW = (x1 - x0).abs() * scaleX;
  final double rawH = (y1 - y0).abs() * scaleY;

  return Rect.fromLTWH(
    math.max(0.0, left),
    math.max(0.0, top),
    math.max(minSize, rawW),
    math.max(minSize, rawH),
  );
}

/// Convenience wrapper that maps an [EditableSpanModel] onto [displaySize] for
/// the page it belongs to.
Rect spanRectForPage({
  required EditableSpanModel span,
  required EditPageModel page,
  required Size displaySize,
  double minSize = kMinSpanBoxSize,
}) {
  return spanDisplayRect(
    bbox: span.bbox,
    pageSize: pageSizePt(page),
    displaySize: displaySize,
    minSize: minSize,
  );
}

/// Convenience wrapper that maps a [VectorObjectModel] onto [displaySize] for
/// the page it belongs to.
Rect vectorObjectRectForPage({
  required VectorObjectModel vec,
  required EditPageModel page,
  required Size displaySize,
  double minSize = kMinSpanBoxSize,
}) {
  return spanDisplayRect(
    bbox: vec.bbox,
    pageSize: pageSizePt(page),
    displaySize: displaySize,
    minSize: minSize,
  );
}
