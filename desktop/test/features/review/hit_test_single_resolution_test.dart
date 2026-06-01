// Hit-test single-resolution tests — Task 11.6.
//
// ============================================================================
//  Property 6: "Hit-test single-resolution"  (Validates: Requirements 8.10)
// ============================================================================
//
// Requirement 8.10: WHEN a user points at a location that falls within more
// than one Detection_Box, THE Review_Canvas SHALL resolve the hit-test to
// exactly ONE box using deterministic top-most precedence.
//
// "Top-most precedence" mirrors the painter's draw order (ReviewPainter draws
// items in ascending index order and, within an item, segments in ascending
// order, so the LAST box drawn sits visually on top). The resolution rule is
// therefore: among every box whose screen rectangle contains the point, pick
// the one with the HIGHEST item index, breaking ties by the HIGHEST segment
// index. `hitTestTopMost` (lib/features/review/review_hit_test.dart) realizes
// this by iterating in reverse and returning the first containing box.
//
// HOW THIS REALIZES PROPERTY 6 (property-based testing note):
// This project has no QuickCheck/Hypothesis-style package in its pubspec; as
// the rest of the suite establishes (see test/dto_roundtrip_test.dart,
// test/features/review/min_box_guard_test.dart), the convention is to realize
// a property with a *seeded* pseudo-random generator (`math.Random(seed)`) that
// produces many randomized-but-valid configurations and asserts the universal
// invariant on every one. The seeded loop is the generator; the assertions are
// the property. Fixed seeds keep any failure reproducible.
//
// The generators below build many OVERLAPPING-box layouts: a target point and
// several Detection_Boxes that provably contain it (plus random noise boxes and
// boxes on other pages), under randomized page geometry (size, pan, zoom). The
// universal invariants asserted for every input:
//
//   1. Single-resolution + precedence: the result equals the box with the
//      maximum (itemIndex, segmentIndex) among all boxes on the page whose
//      screen rect contains the point — computed by an INDEPENDENT oracle that
//      scans forward and keeps the lexicographic maximum, so the test cannot
//      tautologically agree with the implementation (which scans in reverse).
//   2. The resolved box really contains the point, and no containing box ranks
//      higher than it (it is genuinely top-most).
//   3. Determinism: identical inputs always yield the identical single result.
//   4. When no box contains the point, the result is null.
//
// The focused example contract (single box, last-drawn wins, other pages
// ignored, fixed-input determinism) lives in `review_hit_test_test.dart`; this
// file adds the exhaustive randomized coverage rather than repeating those.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/canvas_geometry.dart';
import 'package:qpic_desktop/features/review/review_hit_test.dart';
import 'package:qpic_desktop/models/crop.dart';

/// Randomized cases generated per property. Large enough to cover many
/// overlap/precedence layouts across varied geometry while staying fast.
const int _iterations = 2000;

void main() {
  group('Property 6 — hit-test single-resolution (seeded property generator)',
      () {
    test(
        'a point inside multiple boxes resolves to exactly one — the top-most '
        '(highest item index, then highest segment index)', () {
      final seed = 'Property6-single-resolution'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final _Config c = _genOverlapConfig(r);

        // Sanity on the generator itself: this case really IS a "more than one
        // box" scenario on the target page (Req 8.10's precondition).
        final List<BoxHit> containing = _containingHits(c);
        expect(
          containing.length,
          greaterThanOrEqualTo(2),
          reason: 'iteration $i (seed ${seed + i}): generator must produce an '
              'overlapping layout where >= 2 boxes contain the point.',
        );

        final BoxHit? hit = hitTestTopMost(
          items: c.items,
          pageNumber: c.page,
          geometry: c.geometry,
          localPoint: c.point,
        );

        // Independent oracle: the lexicographically maximum containing (i, s).
        final BoxHit expected = _topMost(containing);

        expect(
          hit,
          expected,
          reason: 'iteration $i (seed ${seed + i}): with ${containing.length} '
              'overlapping boxes the hit must resolve to the top-most one '
              '$expected. point=${c.point}, geom=${c.geometry}',
        );

        // The resolved box genuinely contains the point...
        expect(
          c.geometry.segToScreenRect(c.items[hit!.itemIndex]
                  .segments[hit.segmentIndex])
              .contains(c.point),
          isTrue,
          reason: 'iteration $i (seed ${seed + i}): the resolved box must '
              'contain the pointer.',
        );

        // ...and no other containing box outranks it (it is truly top-most).
        for (final BoxHit other in containing) {
          expect(
            _rank(other) <= _rank(hit),
            isTrue,
            reason: 'iteration $i (seed ${seed + i}): $other contains the point '
                'but outranks the resolved $hit — precedence violated.',
          );
        }
      }
    });

    test('the resolution is deterministic for identical inputs', () {
      final seed = 'Property6-determinism'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final _Config c = _genOverlapConfig(r);

        final BoxHit? first = hitTestTopMost(
          items: c.items,
          pageNumber: c.page,
          geometry: c.geometry,
          localPoint: c.point,
        );

        // Repeated calls with the SAME inputs must return the SAME single box.
        for (var rep = 0; rep < 4; rep++) {
          final BoxHit? again = hitTestTopMost(
            items: c.items,
            pageNumber: c.page,
            geometry: c.geometry,
            localPoint: c.point,
          );
          expect(
            again,
            first,
            reason: 'iteration $i rep $rep (seed ${seed + i}): identical inputs '
                'must yield the identical hit.',
          );
        }
      }
    });

    test('matches the independent oracle for arbitrary mixed layouts '
        '(including no-hit cases)', () {
      final seed = 'Property6-oracle-general'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        // Fully random layout: boxes may or may not contain the point, may sit
        // on other pages, etc. The result must always equal the oracle —
        // exactly one box, or null when nothing contains the point.
        final _Config c = _genMixedConfig(r);

        final BoxHit? hit = hitTestTopMost(
          items: c.items,
          pageNumber: c.page,
          geometry: c.geometry,
          localPoint: c.point,
        );

        final List<BoxHit> containing = _containingHits(c);
        final BoxHit? expected =
            containing.isEmpty ? null : _topMost(containing);

        expect(
          hit,
          expected,
          reason: 'iteration $i (seed ${seed + i}): result must equal the '
              'top-most containing box (or null when none contains the point). '
              'containing=$containing',
        );
      }
    });

    test('returns null when no box contains the point', () {
      final seed = 'Property6-no-hit'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final _Config c = _genDisjointConfig(r);

        // Generator guarantees nothing on the target page contains the point.
        expect(
          _containingHits(c),
          isEmpty,
          reason: 'iteration $i (seed ${seed + i}): generator must place every '
              'box clear of the pointer.',
        );

        final BoxHit? hit = hitTestTopMost(
          items: c.items,
          pageNumber: c.page,
          geometry: c.geometry,
          localPoint: c.point,
        );
        expect(
          hit,
          isNull,
          reason: 'iteration $i (seed ${seed + i}): a pointer over no box must '
              'resolve to null.',
        );
      }
    });
  });
}

// ===========================================================================
//  Generated configuration
// ===========================================================================

/// A complete randomized hit-test scenario.
class _Config {
  _Config({
    required this.items,
    required this.page,
    required this.geometry,
    required this.point,
  });

  final List<AnalyzedItem> items;
  final int page;
  final CanvasGeometry geometry;

  /// The pointer location in widget/screen pixels (derived from a pct point).
  final Offset point;
}

// ===========================================================================
//  Oracle — independent of the implementation's iteration order
// ===========================================================================

/// All (item, segment) hits whose screen rect contains the point ON the target
/// page, found by a forward scan. Order is item-then-segment ascending.
List<BoxHit> _containingHits(_Config c) {
  final List<BoxHit> hits = <BoxHit>[];
  for (var it = 0; it < c.items.length; it++) {
    final List<QuestionSegment> segs = c.items[it].segments;
    for (var s = 0; s < segs.length; s++) {
      final QuestionSegment seg = segs[s];
      if (seg.page != c.page) continue;
      if (c.geometry.segToScreenRect(seg).contains(c.point)) {
        hits.add(BoxHit(it, s));
      }
    }
  }
  return hits;
}

/// The top-most box: maximum (itemIndex, segmentIndex) in lexicographic order.
/// Expressed as a forward max so it does not mirror the implementation's
/// reverse-scan-and-return-first strategy.
BoxHit _topMost(List<BoxHit> hits) {
  BoxHit best = hits.first;
  for (final BoxHit h in hits) {
    if (_rank(h) > _rank(best)) best = h;
  }
  return best;
}

/// A monotone key over (itemIndex, segmentIndex) so that a higher item index
/// always wins and, within the same item, a higher segment index wins. The
/// segment multiplier comfortably exceeds the generated segment counts.
int _rank(BoxHit h) => h.itemIndex * 1000000 + h.segmentIndex;

// ===========================================================================
//  Seeded generators
// ===========================================================================

/// Randomized page geometry. `segToScreenRect` depends only on
/// `pageDisplaySize` and `panOffset`, but we vary `zoom` too so the property is
/// exercised across the full view-state space.
CanvasGeometry _genGeometry(math.Random r) {
  final double w = 200.0 + r.nextDouble() * 2000.0;
  final double h = 200.0 + r.nextDouble() * 2000.0;
  final double zoom = kZoomMin + r.nextDouble() * (kZoomMax - kZoomMin);
  final Offset pan = Offset(
    (r.nextDouble() - 0.5) * 800.0,
    (r.nextDouble() - 0.5) * 800.0,
  );
  return CanvasGeometry(pageDisplaySize: Size(w, h), zoom: zoom, panOffset: pan);
}

/// Page-percent margin used to keep generated boxes strictly around the point,
/// so floating-point and `Rect.contains`' half-open edges can never flip a
/// "contains" verdict.
const double _margin = 1.5;

/// A target pct point with enough room on every side for a containing box.
Offset _genTargetPct(math.Random r) {
  final double px = (_margin * 2) + r.nextDouble() * (100.0 - _margin * 4);
  final double py = (_margin * 2) + r.nextDouble() * (100.0 - _margin * 4);
  return Offset(px, py);
}

/// A segment that strictly contains the pct point [p] on [page].
QuestionSegment _containingSeg(math.Random r, Offset p, int page) {
  final double x0 = r.nextDouble() * (p.dx - _margin);
  final double x1 = (p.dx + _margin) + r.nextDouble() * (100.0 - (p.dx + _margin));
  final double y0 = r.nextDouble() * (p.dy - _margin);
  final double y1 = (p.dy + _margin) + r.nextDouble() * (100.0 - (p.dy + _margin));
  return QuestionSegment(
    page: page,
    xStartPct: x0,
    xEndPct: x1,
    yStartPct: y0,
    yEndPct: y1,
  );
}

/// A fully random normalized segment (end >= start) on a random page in 1..4.
QuestionSegment _noiseSeg(math.Random r) {
  final double a = r.nextDouble() * 100.0;
  final double b = r.nextDouble() * 100.0;
  final double c = r.nextDouble() * 100.0;
  final double d = r.nextDouble() * 100.0;
  return QuestionSegment(
    page: 1 + r.nextInt(4),
    xStartPct: math.min(a, b),
    xEndPct: math.max(a, b),
    yStartPct: math.min(c, d),
    yEndPct: math.max(c, d),
  );
}

/// A normalized segment placed CLEAR of the pct point [p] on [page] — it never
/// contains the point (shifted fully off one axis with margin).
QuestionSegment _disjointSeg(math.Random r, Offset p, int page) {
  // Decide which axis (and side) to clear the point on.
  final bool clearX = r.nextBool();
  double x0, x1, y0, y1;
  if (clearX) {
    if (r.nextBool() && p.dx > _margin * 2) {
      // entirely left of the point
      x1 = p.dx - _margin;
      x0 = r.nextDouble() * x1;
    } else {
      // entirely right of the point
      x0 = math.min(99.0, p.dx + _margin);
      x1 = x0 + r.nextDouble() * (100.0 - x0);
    }
    final double a = r.nextDouble() * 100.0;
    final double b = r.nextDouble() * 100.0;
    y0 = math.min(a, b);
    y1 = math.max(a, b);
  } else {
    if (r.nextBool() && p.dy > _margin * 2) {
      y1 = p.dy - _margin;
      y0 = r.nextDouble() * y1;
    } else {
      y0 = math.min(99.0, p.dy + _margin);
      y1 = y0 + r.nextDouble() * (100.0 - y0);
    }
    final double a = r.nextDouble() * 100.0;
    final double b = r.nextDouble() * 100.0;
    x0 = math.min(a, b);
    x1 = math.max(a, b);
  }
  return QuestionSegment(
    page: page,
    xStartPct: x0,
    xEndPct: x1,
    yStartPct: y0,
    yEndPct: y1,
  );
}

AnalyzedItem _item(int n, List<QuestionSegment> segs) => AnalyzedItem(
      qNum: '$n',
      source: 'auto',
      segments: segs,
    );

/// Builds an OVERLAPPING layout: several boxes that contain the point (spread
/// across varied item/segment positions and interleaved with noise) on a
/// random target page, guaranteeing at least two containing boxes.
_Config _genOverlapConfig(math.Random r) {
  final CanvasGeometry geometry = _genGeometry(r);
  final Offset pct = _genTargetPct(r);
  final int page = 1 + r.nextInt(3);
  final Offset point = geometry.pctToScreen(pct.dx, pct.dy);

  final int nItems = 2 + r.nextInt(4); // 2..5 items
  final List<AnalyzedItem> items = <AnalyzedItem>[];
  int containing = 0;

  for (var k = 0; k < nItems; k++) {
    final int mSegs = 1 + r.nextInt(3); // 1..3 segments
    final List<QuestionSegment> segs = <QuestionSegment>[];
    for (var s = 0; s < mSegs; s++) {
      if (r.nextInt(100) < 55) {
        segs.add(_containingSeg(r, pct, page));
        containing++;
      } else {
        // Noise: random box on a random page (may or may not contain).
        segs.add(_noiseSeg(r));
      }
    }
    items.add(_item(k + 1, segs));
  }

  // Guarantee the "more than one box" precondition: top up containing boxes by
  // appending them to random existing items at random positions.
  while (containing < 2) {
    final int k = r.nextInt(items.length);
    final List<QuestionSegment> segs =
        List<QuestionSegment>.of(items[k].segments)
          ..insert(
            r.nextInt(items[k].segments.length + 1),
            _containingSeg(r, pct, page),
          );
    items[k] = _item(k + 1, segs);
    containing++;
  }

  return _Config(items: items, page: page, geometry: geometry, point: point);
}

/// Builds a fully random layout: any mix of containing, noise, and other-page
/// boxes (or none), so the oracle comparison also covers the null path.
_Config _genMixedConfig(math.Random r) {
  final CanvasGeometry geometry = _genGeometry(r);
  final Offset pct = _genTargetPct(r);
  final int page = 1 + r.nextInt(3);
  final Offset point = geometry.pctToScreen(pct.dx, pct.dy);

  final int nItems = r.nextInt(5); // 0..4 items
  final List<AnalyzedItem> items = <AnalyzedItem>[];
  for (var k = 0; k < nItems; k++) {
    final int mSegs = 1 + r.nextInt(3);
    final List<QuestionSegment> segs = <QuestionSegment>[];
    for (var s = 0; s < mSegs; s++) {
      switch (r.nextInt(3)) {
        case 0:
          segs.add(_containingSeg(r, pct, page));
          break;
        case 1:
          segs.add(_disjointSeg(r, pct, page));
          break;
        default:
          segs.add(_noiseSeg(r));
      }
    }
    items.add(_item(k + 1, segs));
  }
  return _Config(items: items, page: page, geometry: geometry, point: point);
}

/// Builds a layout where NO box on the target page contains the point: every
/// segment is placed clear of it (on the target page) or on another page.
_Config _genDisjointConfig(math.Random r) {
  final CanvasGeometry geometry = _genGeometry(r);
  final Offset pct = _genTargetPct(r);
  final int page = 1 + r.nextInt(3);
  final Offset point = geometry.pctToScreen(pct.dx, pct.dy);

  final int nItems = 1 + r.nextInt(4); // 1..4 items
  final List<AnalyzedItem> items = <AnalyzedItem>[];
  for (var k = 0; k < nItems; k++) {
    final int mSegs = 1 + r.nextInt(3);
    final List<QuestionSegment> segs = <QuestionSegment>[];
    for (var s = 0; s < mSegs; s++) {
      if (r.nextBool()) {
        // Clear of the point on the target page.
        segs.add(_disjointSeg(r, pct, page));
      } else {
        // On a different page (never considered for `page`).
        final int otherPage = page + 1 + r.nextInt(3);
        segs.add(_disjointSeg(r, pct, otherPage));
      }
    }
    items.add(_item(k + 1, segs));
  }
  return _Config(items: items, page: page, geometry: geometry, point: point);
}
