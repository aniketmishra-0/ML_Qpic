/// Pure review-canvas geometry & numbering helpers.
///
/// These are direct ports of the web canvas logic in `static/index.html`
/// (`segIoU`, `findOverlappingItem`, `nextAutoNumber`, and the `endDraw`
/// min-box guard). They are **pure functions** — no engine logic, no widget
/// state, no I/O — so the Review Canvas controller and the property/unit tests
/// (tasks 11.2–11.4) can exercise them in isolation.
///
/// All coordinates are page-percentages (0–100), identical to the engine's
/// `QuestionSegment` contract, so the math reproduces the web behavior exactly:
///   * Req 8.5  — discard a drag smaller than 1.5% of page width or height.
///   * Req 8.11 — a new same-type box with IoU ≥ 0.6 against an existing box
///                replaces it (keeping its number) instead of duplicating.
///   * Req 8.13 — `nextAutoNumber` = max existing same-type number + 1.
library;

import 'dart:math' as math;

import '../../models/crop.dart';

/// Minimum drawn-box size, in page-percent, below which a drag is discarded.
///
/// Verbatim from the web `endDraw` guard: a box must be at least 1.5% of the
/// page width AND 1.5% of the page height to become a [QuestionSegment]
/// (Req 8.5).
const double kMinBoxPct = 1.5;

/// IoU threshold at or above which a freshly drawn same-type box is treated as
/// a re-selection of an existing item rather than a new duplicate.
///
/// Verbatim from the web `findOverlappingItem` (`const OVERLAP = 0.6`),
/// Req 8.11.
const double kOverlap = 0.6;

/// Backwards-compatible alias matching the web identifier `OVERLAP`.
// ignore: constant_identifier_names
const double OVERLAP = kOverlap;

/// Intersection-over-union of two single-page boxes, in page-percent space.
///
/// Ported verbatim from the web `segIoU`. Boxes on different pages never
/// overlap (returns 0). Used to tell whether a freshly drawn box lands on top
/// of an item that already exists (so the caller replaces it instead of
/// creating a duplicate).
double segIoU(QuestionSegment a, QuestionSegment b) {
  if (a.page != b.page) return 0;
  final double ix0 = math.max(a.xStartPct, b.xStartPct);
  final double iy0 = math.max(a.yStartPct, b.yStartPct);
  final double ix1 = math.min(a.xEndPct, b.xEndPct);
  final double iy1 = math.min(a.yEndPct, b.yEndPct);
  final double inter = math.max(0, ix1 - ix0) * math.max(0, iy1 - iy0);
  if (inter <= 0) return 0;
  final double areaA =
      math.max(0, a.xEndPct - a.xStartPct) * math.max(0, a.yEndPct - a.yStartPct);
  final double areaB =
      math.max(0, b.xEndPct - b.xStartPct) * math.max(0, b.yEndPct - b.yStartPct);
  final double union = areaA + areaB - inter;
  return union > 0 ? inter / union : 0;
}

/// Returns the index of an existing item of the SAME kind whose region
/// substantially overlaps [seg] (any of its segments has `segIoU >= OVERLAP`),
/// or `-1` when there is none.
///
/// Ported verbatim from the web `findOverlappingItem`. Drawing over a detected
/// (or earlier manual) question means "fix this one", not "add another", so the
/// caller reuses the returned item — preserving its number — instead of
/// creating a duplicate. This is the exact guard the web code documents for the
/// "redrew Q3 → still one Q3, not two" behavior (Req 8.11).
int findOverlappingItem(
  QuestionSegment seg,
  bool isSolution,
  List<AnalyzedItem> items,
) {
  return items.indexWhere(
    (it) =>
        it.isSolution == isSolution &&
        it.segments.any((s) => segIoU(s, seg) >= OVERLAP),
  );
}

/// Returns the next auto-assigned number for a new box of the given type:
/// the highest existing same-type number plus one, as a string.
///
/// Ported verbatim from the web `nextAutoNumber`. Questions and solutions are
/// numbered independently; the first leading run of digits in each same-type
/// `qNum` is parsed, and items of the other type are ignored. With no existing
/// same-type items the result is `"1"` (Req 8.13).
String nextAutoNumber(bool isSolution, List<AnalyzedItem> items) {
  int max = 0;
  for (final it in items) {
    if (it.isSolution != isSolution) continue;
    final match = RegExp(r'\d+').firstMatch(it.qNum);
    if (match != null) {
      max = math.max(max, int.parse(match.group(0)!));
    }
  }
  return (max + 1).toString();
}

/// Whether a drag should be discarded as too small to become a box.
///
/// Verbatim from the web `endDraw` guard `(x1 - x0) < 1.5 || (y1 - y0) < 1.5`:
/// a box is rejected when its width is below 1.5% of the page width OR its
/// height is below 1.5% of the page height. [seg] is expected to be normalized
/// (end ≥ start), exactly as the web builds the drawn segment (Req 8.5).
bool isDragTooSmall(QuestionSegment seg) {
  final double width = seg.xEndPct - seg.xStartPct;
  final double height = seg.yEndPct - seg.yStartPct;
  return width < kMinBoxPct || height < kMinBoxPct;
}
