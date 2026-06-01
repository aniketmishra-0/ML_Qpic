// Property 4 — "Zoom is bounded" (task 10.3).
//
// Two invariants for the Review Canvas geometry:
//   * The displayed zoom factor is ALWAYS within [0.25, 6.0], no matter what
//     (possibly out-of-range) zoom is requested — on construction, via the
//     fit-width factory, and via copyWith (Req 8.9).
//   * Panning never mutates a box's page-percentage coordinates: changing
//     panOffset only translates the on-screen overlay by the pan delta and the
//     pct↔screen round-trip is pan-independent, so stored box coordinates are
//     untouched (Req 8.8).
//
// **Validates: Requirements 8.8, 8.9**
//
// There is no property-testing package in this project, so each property is
// checked by sampling a large number of generated inputs with a SEEDED RNG.
// The seed is fixed, so any failure is deterministic and the printed input is a
// reproducible counterexample.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/features/review/canvas_geometry.dart';
import 'package:qpic_desktop/models/crop.dart' show QuestionSegment;

/// Number of generated samples per property. Large enough to exercise the input
/// space, small enough to stay fast under `flutter test`.
const int _kSamples = 2000;

/// Generates a finite zoom request spanning well outside [0.25, 6.0], plus the
/// exact boundaries and infinities, so the clamp is stressed from every side.
double _genZoom(math.Random rng) {
  switch (rng.nextInt(10)) {
    case 0:
      return kZoomMin; // exact lower bound
    case 1:
      return kZoomMax; // exact upper bound
    case 2:
      return double.infinity; // clamps down to max
    case 3:
      return double.negativeInfinity; // clamps up to min
    case 4:
      return 0.0; // below range
    case 5:
      return -rng.nextDouble() * 1000.0; // negative, below range
    case 6:
      return rng.nextDouble() * 0.25; // (0, 0.25) — just below range
    case 7:
      return kZoomMin + rng.nextDouble() * (kZoomMax - kZoomMin); // in range
    case 8:
      return kZoomMax + rng.nextDouble() * 1000.0; // above range
    default:
      return (rng.nextDouble() - 0.5) * 2000.0; // anywhere in [-1000, 1000]
  }
}

/// A non-degenerate displayed page size (image-content px after zoom).
Size _genSize(math.Random rng) {
  final double w = 1.0 + rng.nextDouble() * 5000.0;
  final double h = 1.0 + rng.nextDouble() * 5000.0;
  return Size(w, h);
}

/// A pan/scroll translation in either direction (incl. zero).
Offset _genPan(math.Random rng) {
  return Offset(
    (rng.nextDouble() - 0.5) * 4000.0,
    (rng.nextDouble() - 0.5) * 4000.0,
  );
}

/// A page-percentage box with 0 <= start <= end <= 100 on both axes.
QuestionSegment _genSegment(math.Random rng) {
  final double xa = rng.nextDouble() * 100.0;
  final double xb = rng.nextDouble() * 100.0;
  final double ya = rng.nextDouble() * 100.0;
  final double yb = rng.nextDouble() * 100.0;
  return QuestionSegment(
    page: 1 + rng.nextInt(20),
    xStartPct: math.min(xa, xb),
    xEndPct: math.max(xa, xb),
    yStartPct: math.min(ya, yb),
    yEndPct: math.max(ya, yb),
  );
}

bool _inZoomRange(double z) => z >= kZoomMin && z <= kZoomMax;

void main() {
  group('Property 4 — displayed zoom is always within [0.25, 6.0] (Req 8.9)', () {
    test('clampZoom maps every requested zoom into range, idempotently', () {
      final rng = math.Random(0x20A4);
      for (int i = 0; i < _kSamples; i++) {
        final double z = _genZoom(rng);
        final double clamped = clampZoom(z);
        expect(
          _inZoomRange(clamped),
          isTrue,
          reason: 'clampZoom($z) = $clamped escaped [$kZoomMin, $kZoomMax]',
        );
        // Clamping an already-clamped value changes nothing.
        expect(
          clampZoom(clamped),
          clamped,
          reason: 'clampZoom not idempotent for input $z',
        );
        // Values already in range pass through unchanged.
        if (_inZoomRange(z)) {
          expect(clamped, z, reason: 'in-range $z was altered to $clamped');
        }
      }
    });

    test('CanvasGeometry never reports an out-of-range zoom on construction', () {
      final rng = math.Random(0x5EED);
      for (int i = 0; i < _kSamples; i++) {
        final double z = _genZoom(rng);
        final geometry = CanvasGeometry(
          pageDisplaySize: _genSize(rng),
          zoom: z,
          panOffset: _genPan(rng),
        );
        expect(
          _inZoomRange(geometry.zoom),
          isTrue,
          reason: 'CanvasGeometry(zoom: $z) reported ${geometry.zoom}',
        );
      }
    });

    test('fromFitWidth clamps zoom and scales the page by the clamped factor',
        () {
      final rng = math.Random(0xF17);
      for (int i = 0; i < _kSamples; i++) {
        final double z = _genZoom(rng);
        final Size fit = _genSize(rng);
        final geometry = CanvasGeometry.fromFitWidth(
          fitWidthSize: fit,
          zoom: z,
          panOffset: _genPan(rng),
        );
        final double clamped = clampZoom(z);
        expect(
          _inZoomRange(geometry.zoom),
          isTrue,
          reason: 'fromFitWidth(zoom: $z) reported ${geometry.zoom}',
        );
        // pageDisplaySize == fit-width size * CLAMPED zoom (fit-width == 1.0).
        expect(geometry.pageDisplaySize.width, closeTo(fit.width * clamped, 1e-6));
        expect(
            geometry.pageDisplaySize.height, closeTo(fit.height * clamped, 1e-6));
      }
    });

    test('copyWith re-clamps a freshly requested zoom', () {
      final rng = math.Random(0xC0FFEE);
      for (int i = 0; i < _kSamples; i++) {
        final base = CanvasGeometry(
          pageDisplaySize: _genSize(rng),
          zoom: kFitWidthZoom,
          panOffset: _genPan(rng),
        );
        final double z = _genZoom(rng);
        final updated = base.copyWith(zoom: z);
        expect(
          _inZoomRange(updated.zoom),
          isTrue,
          reason: 'copyWith(zoom: $z) reported ${updated.zoom}',
        );
      }
    });
  });

  group('Property 4 — panning never mutates box pct coordinates (Req 8.8)', () {
    test('changing panOffset leaves every stored segment pct unchanged', () {
      final rng = math.Random(0x9A11);
      for (int i = 0; i < _kSamples; i++) {
        final QuestionSegment seg = _genSegment(rng);
        // Snapshot the original page-percentage coordinates.
        final double x0 = seg.xStartPct;
        final double x1 = seg.xEndPct;
        final double y0 = seg.yStartPct;
        final double y1 = seg.yEndPct;

        final geometry = CanvasGeometry(
          pageDisplaySize: _genSize(rng),
          zoom: _genZoom(rng),
          panOffset: _genPan(rng),
        );
        // Pan to a brand-new offset (what a scroll/drag does).
        final panned = geometry.copyWith(panOffset: _genPan(rng));

        // Rendering against either geometry must not touch the segment data.
        panned.segToScreenRect(seg);
        geometry.segToScreenRect(seg);

        expect(seg.xStartPct, x0, reason: 'pan mutated xStartPct');
        expect(seg.xEndPct, x1, reason: 'pan mutated xEndPct');
        expect(seg.yStartPct, y0, reason: 'pan mutated yStartPct');
        expect(seg.yEndPct, y1, reason: 'pan mutated yEndPct');
        // The pan changed (or was equal) but the zoom stayed put either way.
        expect(panned.zoom, geometry.zoom);
      }
    });

    test('pan only translates the overlay by the pan delta (overlays stay aligned)',
        () {
      final rng = math.Random(0xA11A);
      for (int i = 0; i < _kSamples; i++) {
        final Size size = _genSize(rng);
        final double zoom = _genZoom(rng);
        final Offset panA = _genPan(rng);
        final Offset panB = _genPan(rng);
        final QuestionSegment seg = _genSegment(rng);

        final a = CanvasGeometry(
            pageDisplaySize: size, zoom: zoom, panOffset: panA);
        final b = a.copyWith(panOffset: panB);

        final Rect rectA = a.segToScreenRect(seg);
        final Rect rectB = b.segToScreenRect(seg);
        final Offset delta = panB - panA;

        // Each corner shifts by exactly the pan delta — pure translation.
        expect(rectB.left - rectA.left, closeTo(delta.dx, 1e-6));
        expect(rectB.top - rectA.top, closeTo(delta.dy, 1e-6));
        expect(rectB.right - rectA.right, closeTo(delta.dx, 1e-6));
        expect(rectB.bottom - rectA.bottom, closeTo(delta.dy, 1e-6));
        // Size (and therefore zoom-scaled extent) is unaffected by panning.
        expect(rectB.width, closeTo(rectA.width, 1e-6));
        expect(rectB.height, closeTo(rectA.height, 1e-6));
      }
    });

    test('pct->screen->pct round-trips back to the same percent under any pan',
        () {
      final rng = math.Random(0xB07);
      for (int i = 0; i < _kSamples; i++) {
        final geometry = CanvasGeometry(
          pageDisplaySize: _genSize(rng),
          zoom: _genZoom(rng),
          panOffset: _genPan(rng),
        );
        final double xPct = rng.nextDouble() * 100.0;
        final double yPct = rng.nextDouble() * 100.0;

        final Offset screen = geometry.pctToScreen(xPct, yPct);
        final Offset back = geometry.screenToPct(screen);

        expect(back.dx, closeTo(xPct, 1e-6),
            reason: 'x round-trip drifted under pan ${geometry.panOffset}');
        expect(back.dy, closeTo(yPct, 1e-6),
            reason: 'y round-trip drifted under pan ${geometry.panOffset}');
      }
    });
  });

  group('zoom-bound example cases (unit)', () {
    test('exact and obvious out-of-range inputs clamp as specified', () {
      expect(clampZoom(0.25), 0.25);
      expect(clampZoom(6.0), 6.0);
      expect(clampZoom(1.0), 1.0);
      expect(clampZoom(0.1), kZoomMin);
      expect(clampZoom(0.0), kZoomMin);
      expect(clampZoom(-5.0), kZoomMin);
      expect(clampZoom(7.5), kZoomMax);
      expect(clampZoom(1000.0), kZoomMax);
      expect(clampZoom(double.infinity), kZoomMax);
      expect(clampZoom(double.negativeInfinity), kZoomMin);
    });
  });

  group('pan-invariance example cases (unit)', () {
    test('a concrete pan shifts the screen rect but not the pct coordinates',
        () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10,
        xEndPct: 50,
        yStartPct: 20,
        yEndPct: 60,
      );
      final base = CanvasGeometry(
        pageDisplaySize: const Size(800, 1000),
        zoom: 1.0,
      );
      // At zero pan: x in px = pct/100 * width, y = pct/100 * height.
      final r0 = base.segToScreenRect(seg);
      expect(r0, const Rect.fromLTRB(80, 200, 400, 600));

      final panned = base.copyWith(panOffset: const Offset(15, -25));
      final r1 = panned.segToScreenRect(seg);
      expect(r1, const Rect.fromLTRB(95, 175, 415, 575));

      // The segment object itself is untouched.
      expect(seg.xStartPct, 10);
      expect(seg.xEndPct, 50);
      expect(seg.yStartPct, 20);
      expect(seg.yEndPct, 60);
    });
  });
}
