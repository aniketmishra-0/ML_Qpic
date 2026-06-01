// Min-box guard tests — Task 11.3.
//
// ============================================================================
//  Property 7: "Min-box guard"  (Validates: Requirements 8.5)
// ============================================================================
//
// Requirement 8.5: IF a user's drag produces a region smaller than 1.5% of
// page width OR 1.5% of page height, THEN the Review_Canvas SHALL discard the
// drag and SHALL NOT create a Detection_Box. Conversely (Req 8.4) a drag whose
// width is at least 1.5% AND whose height is at least 1.5% DOES create a box.
//
// The guard is realized by `isDragTooSmall` in
// `lib/features/review/box_logic.dart`, a verbatim port of the web `endDraw`
// check `(x1 - x0) < 1.5 || (y1 - y0) < 1.5`. Because the box is stored in
// page-percentage space (0..100), "1.5% of page width/height" is simply 1.5
// units of width/height — independent of the on-screen pixel size or zoom.
//
// HOW THIS REALIZES PROPERTY 7 (property-based testing note):
// This project has no QuickCheck/Hypothesis-style package in its pubspec, and
// (as the DTO round-trip suite already established) the convention here is to
// realize a property with a *seeded* pseudo-random generator (`math.Random`)
// that produces many randomized-but-valid drags and asserts the universal
// invariant on every one. The seeded loop is the generator; the assertions are
// the property. Fixed seeds keep any failure reproducible.
//
// The universal invariant under test, for ANY normalized drag (end >= start)
// in page-percent space:
//
//     a box is created  <=>  width >= 1.5  AND  height >= 1.5
//     no box is created  <=>  width < 1.5  OR   height < 1.5
//
// To exercise the input space intelligently the generator draws from buckets
// that straddle the 1.5% threshold on each axis (both-small, width-small,
// height-small, both-large, and exactly-on-the-boundary), with the box placed
// at a random in-range position so the test confirms the guard depends only on
// SIZE, never on WHERE the drag sits on the page.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/box_logic.dart';
import 'package:qpic_desktop/models/crop.dart';

/// Number of randomized cases generated per property. Large enough to cover
/// the threshold neighborhood on both axes while keeping the suite fast.
const int _iterations = 2000;

/// Page-percent threshold below which a drag is discarded (Req 8.5).
const double _t = kMinBoxPct; // 1.5

void main() {
  group('Property 7 — min-box guard (seeded property generator)', () {
    test('a box is created iff width >= 1.5% AND height >= 1.5%', () {
      final seed = 'Property7-min-box'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final seg = _genDrag(r);

        final double width = seg.xEndPct - seg.xStartPct;
        final double height = seg.yEndPct - seg.yStartPct;

        // The mathematical definition of the guard, computed independently of
        // the implementation so the test can't tautologically agree with it.
        final bool shouldBeRejected = width < _t || height < _t;
        final bool createsBox = !isDragTooSmall(seg);

        expect(
          isDragTooSmall(seg),
          shouldBeRejected,
          reason: 'iteration $i (seed ${seed + i}): width=$width height=$height '
              '— guard must reject exactly when an axis is below $_t%.',
        );

        // Restate the contract from the "creates a box" direction (Req 8.4/8.5).
        expect(
          createsBox,
          width >= _t && height >= _t,
          reason: 'iteration $i (seed ${seed + i}): a box may be created only '
              'when BOTH axes are at least $_t%.',
        );
      }
    });

    test('drags failing either threshold create no box', () {
      final seed = 'Property7-too-small'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        // Force at least one axis below the threshold.
        final bool shrinkWidth = r.nextBool();
        final bool shrinkHeight = !shrinkWidth || r.nextBool();
        final seg = _genDrag(
          r,
          widthBucket: shrinkWidth ? _Bucket.below : _Bucket.aboveOrEqual,
          heightBucket: shrinkHeight ? _Bucket.below : _Bucket.aboveOrEqual,
        );

        expect(
          isDragTooSmall(seg),
          isTrue,
          reason: 'iteration $i (seed ${seed + i}): a drag with an axis below '
              '$_t% must be discarded. seg=${_fmt(seg)}',
        );
      }
    });

    test('drags meeting both thresholds always create a box', () {
      final seed = 'Property7-big-enough'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final seg = _genDrag(
          r,
          widthBucket: _Bucket.aboveOrEqual,
          heightBucket: _Bucket.aboveOrEqual,
        );

        expect(
          isDragTooSmall(seg),
          isFalse,
          reason: 'iteration $i (seed ${seed + i}): a drag with both axes at '
              'least $_t% must create a box. seg=${_fmt(seg)}',
        );
      }
    });

    test('the guard ignores WHERE the drag sits (position invariance)', () {
      // Same size, different positions => same verdict.
      final seed = 'Property7-position'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final double width = _pctSize(r);
        final double height = _pctSize(r);

        final bool expectedTooSmall = width < _t || height < _t;

        // Place the same-sized box at several legal positions on the page.
        for (var p = 0; p < 4; p++) {
          final double x0 = _legalStart(r, width);
          final double y0 = _legalStart(r, height);
          final seg = QuestionSegment(
            page: 1,
            xStartPct: x0,
            xEndPct: x0 + width,
            yStartPct: y0,
            yEndPct: y0 + height,
          );
          expect(
            isDragTooSmall(seg),
            expectedTooSmall,
            reason: 'iteration $i pos $p (seed ${seed + i}): verdict must depend '
                'only on size (w=$width h=$height), not position. '
                'seg=${_fmt(seg)}',
          );
        }
      }
    });
  });

  // Targeted examples / edge cases that complement the property above.
  group('min-box guard — examples and boundaries', () {
    test('a comfortably large drag creates a box', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10,
        xEndPct: 60,
        yStartPct: 20,
        yEndPct: 80,
      );
      expect(isDragTooSmall(seg), isFalse);
    });

    test('a tiny drag on both axes is discarded', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10,
        xEndPct: 11, // width 1.0% < 1.5%
        yStartPct: 10,
        yEndPct: 11, // height 1.0% < 1.5%
      );
      expect(isDragTooSmall(seg), isTrue);
    });

    test('width below threshold alone is discarded (height large)', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10,
        xEndPct: 11.4, // width 1.4% < 1.5%
        yStartPct: 10,
        yEndPct: 90, // height 80% >= 1.5%
      );
      expect(isDragTooSmall(seg), isTrue);
    });

    test('height below threshold alone is discarded (width large)', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10,
        xEndPct: 90, // width 80% >= 1.5%
        yStartPct: 10,
        yEndPct: 11.4, // height 1.4% < 1.5%
      );
      expect(isDragTooSmall(seg), isTrue);
    });

    test('exactly 1.5% on both axes is NOT discarded (boundary, Req 8.4)', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10.0,
        xEndPct: 11.5, // width exactly 1.5%
        yStartPct: 20.0,
        yEndPct: 21.5, // height exactly 1.5%
      );
      // The web guard uses strict `<`, so a box exactly at the threshold stays.
      expect(isDragTooSmall(seg), isFalse);
    });

    test('just below 1.5% on one axis IS discarded', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10.0,
        xEndPct: 11.49, // width 1.49% < 1.5%
        yStartPct: 20.0,
        yEndPct: 50.0,
      );
      expect(isDragTooSmall(seg), isTrue);
    });

    test('a zero-area drag (single click) is discarded', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 42,
        xEndPct: 42,
        yStartPct: 42,
        yEndPct: 42,
      );
      expect(isDragTooSmall(seg), isTrue);
    });
  });
}

// ===========================================================================
//  Seeded generators
// ===========================================================================

/// Which side of the 1.5% threshold a generated axis should fall on.
enum _Bucket { below, aboveOrEqual, any }

/// Generates a normalized drag (end >= start, all coords in 0..100) whose
/// width/height land in the requested buckets relative to the 1.5% threshold.
QuestionSegment _genDrag(
  math.Random r, {
  _Bucket widthBucket = _Bucket.any,
  _Bucket heightBucket = _Bucket.any,
}) {
  final double width = _sizeForBucket(r, widthBucket);
  final double height = _sizeForBucket(r, heightBucket);
  final double x0 = _legalStart(r, width);
  final double y0 = _legalStart(r, height);
  return QuestionSegment(
    page: 1 + r.nextInt(50),
    xStartPct: x0,
    xEndPct: x0 + width,
    yStartPct: y0,
    yEndPct: y0 + height,
  );
}

/// A page-percent size in [0, 100] that straddles the threshold, biased toward
/// the threshold neighborhood so the boundary is exercised heavily.
double _pctSize(math.Random r) => _sizeForBucket(r, _Bucket.any);

/// Produces a size on the requested side of the threshold.
double _sizeForBucket(math.Random r, _Bucket bucket) {
  switch (bucket) {
    case _Bucket.below:
      // [0, 1.49] — strictly below the 1.5% threshold even after rounding to
      // 2 decimals (round2 of any value < 1.49 stays <= 1.49 < 1.5).
      return _round2(r.nextDouble() * (_t - 0.01));
    case _Bucket.aboveOrEqual:
      // [1.5, 100]
      return _round2(_t + r.nextDouble() * (100.0 - _t));
    case _Bucket.any:
      // Bias around the threshold: half the time draw from a tight band
      // [0, 3) around 1.5, otherwise from the full [0, 100] range.
      if (r.nextBool()) {
        return _round2(r.nextDouble() * (2 * _t)); // [0, 3.0)
      }
      return _round2(r.nextDouble() * 100.0); // [0, 100]
  }
}

/// A legal start coordinate so that `start + size` stays within 0..100.
double _legalStart(math.Random r, double size) {
  final double maxStart = math.max(0.0, 100.0 - size);
  return _round2(r.nextDouble() * maxStart);
}

/// Round to 2 decimals to keep values clean and reproducible.
double _round2(double v) => (v * 100).round() / 100.0;

String _fmt(QuestionSegment s) =>
    'x[${s.xStartPct}..${s.xEndPct}] y[${s.yStartPct}..${s.yEndPct}] '
    '(w=${s.xEndPct - s.xStartPct}, h=${s.yEndPct - s.yStartPct})';
