/// Deterministic top-most hit-testing for the Review Canvas (Req 8.10).
///
/// The web canvas relies on DOM stacking: `drawExistingBoxes` appends every
/// box in item order, then segment order, so the LAST box appended paints on
/// top and is the one a pointer event lands on (later siblings cover earlier
/// ones). We reproduce that ordering explicitly here instead of leaning on a
/// framework's implicit stacking, so a pointer that falls inside more than one
/// Detection_Box always resolves to exactly one box, and to the SAME box for
/// the same inputs (Req 8.10).
///
/// This is a pure function — no widget state, no I/O, no engine logic — so the
/// gesture layer (task 11.5) and the single-resolution tests (task 11.6) share
/// one source of truth.
library;

import 'dart:ui' show Offset, Rect;

import '../../models/crop.dart';
import 'canvas_geometry.dart';

/// A resolved hit: the [itemIndex] into the items list and the [segmentIndex]
/// into that item's segments that the pointer landed on.
class BoxHit {
  const BoxHit(this.itemIndex, this.segmentIndex);

  /// Index into the items list of the hit item.
  final int itemIndex;

  /// Index into `items[itemIndex].segments` of the hit segment.
  final int segmentIndex;

  @override
  bool operator ==(Object other) =>
      other is BoxHit &&
      other.itemIndex == itemIndex &&
      other.segmentIndex == segmentIndex;

  @override
  int get hashCode => Object.hash(itemIndex, segmentIndex);

  @override
  String toString() => 'BoxHit(item: $itemIndex, segment: $segmentIndex)';
}

/// Resolves [localPoint] (widget/screen px) to exactly one Detection_Box on
/// [pageNumber], or `null` when it falls on no box.
///
/// Top-most precedence (Req 8.10): [ReviewPainter] draws items in ascending
/// index order and, within an item, segments in ascending order, so the
/// box drawn LAST sits visually on top. This function therefore iterates in
/// reverse — highest item index first, and within each item the highest
/// segment index first — and returns the first box whose screen rectangle
/// contains the point. Because the iteration order is fixed and total, the
/// result is fully deterministic: identical inputs always yield the identical
/// [BoxHit], even when several boxes overlap the point.
///
/// Only segments on [pageNumber] are considered, matching the painter, which
/// renders just the current page's boxes (Req 8.12).
BoxHit? hitTestTopMost({
  required List<AnalyzedItem> items,
  required int pageNumber,
  required CanvasGeometry geometry,
  required Offset localPoint,
}) {
  for (int i = items.length - 1; i >= 0; i--) {
    final List<QuestionSegment> segments = items[i].segments;
    for (int s = segments.length - 1; s >= 0; s--) {
      final QuestionSegment seg = segments[s];
      if (seg.page != pageNumber) continue;
      final Rect rect = geometry.segToScreenRect(seg);
      if (rect.contains(localPoint)) {
        return BoxHit(i, s);
      }
    }
  }
  return null;
}
