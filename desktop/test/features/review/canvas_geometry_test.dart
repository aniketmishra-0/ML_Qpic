// CanvasGeometry transform tests — Task 10.2.
//
// ============================================================================
//  Property 3: "Coordinate fidelity"  (Validates: Requirements 8.1, 8.4, 8.6,
//  8.8)
// ============================================================================
//
// The Review Canvas stores every box in page-PERCENTAGE coordinates (0..100 of
// page width/height, end >= start — Req 8.1) and converts to/from screen
// pixels through `CanvasGeometry`. The single invariant that keeps the painter
// and the gesture code in lock-step is:
//
//   * ROUND-TRIP: for any in-range point `p` (xPct, yPct in 0..100),
//       screenToPct(pctToScreen(p)) == p   (within float tolerance)
//     regardless of the current zoom or pan. The view transform may move the
//     pixel anywhere on (or off) the screen, but mapping back recovers the
//     exact same percentage — overlays therefore stay glued to page content
//     across zoom and pan (Req 8.8).
//
//   * CLAMP / STORED-COORDS: `screenToPct` always lands in 0..100 (the web
//     `clamp01`/`pointPct` clamp), so a box drawn or re-selected from ANY two
//     pointer positions — even ones dragged outside the page — yields stored
//     coordinates within 0..100 with end >= start (Req 8.4, 8.6). This holds
//     across every zoom factor and pan offset.
//
// HOW THIS REALIZES PROPERTY 3 (property-based testing note):
// There is no QuickCheck/Hypothesis-style package in this project's pubspec,
// and the existing suite (see `dto_roundtrip_test.dart`) realizes its
// properties with a *seeded pseudo-random generator* (`math.Random(seed)`)
// that drives a large number of randomized-but-valid cases. We follow the same
// pattern here: the seeded loops below are the generators (varying zoom across
// the full 0.25..6.0 range, pan across a wide pixel span, page sizes built both
// directly and via fit-width, and points/pointers across and beyond the page),
// and the `expect`s are the universal properties. Fixed seeds keep any failure
// reproducible.
//
// A handful of hand-checked example unit tests sit alongside the property loops
// to pin down exact behavior at boundaries (corners, zero-size axes, pan).

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/canvas_geometry.dart';
import 'package:qpic_desktop/models/crop.dart';

/// Number of randomized cases per property. Large enough to exercise the input
/// space (full zoom range, wide pan, page sizes, in/out-of-page pointers)
/// while keeping the suite fast.
const int _iterations = 2000;

/// Absolute tolerance for the percent round-trip. The transform is a single
/// multiply + add then the inverse; over the generated magnitudes (page sizes
/// up to ~18000 px, pan up to ±3000 px) double error stays well under 1e-9, so
/// 1e-6 is a comfortable, meaningful bound.
const double _tol = 1e-6;

void main() {
  group('CanvasGeometry — example transforms', () {
    final geo = CanvasGeometry(
      pageDisplaySize: const Size(800, 1000),
      zoom: 1.0,
    );

    test('pctToScreen maps the page box corners (no pan)', () {
      expect(geo.pctToScreen(0, 0), const Offset(0, 0));
      expect(geo.pctToScreen(100, 100), const Offset(800, 1000));
      expect(geo.pctToScreen(50, 50), const Offset(400, 500));
    });

    test('pctToScreen adds the pan offset', () {
      final panned = geo.copyWith(panOffset: const Offset(10, 20));
      expect(panned.pctToScreen(0, 0), const Offset(10, 20));
      expect(panned.pctToScreen(100, 100), const Offset(810, 1020));
    });

    test('screenToPct inverts pctToScreen exactly at known points', () {
      expect(geo.screenToPct(const Offset(0, 0)), const Offset(0, 0));
      expect(geo.screenToPct(const Offset(800, 1000)), const Offset(100, 100));
      expect(geo.screenToPct(const Offset(400, 500)), const Offset(50, 50));
    });

    test('screenToPct clamps pixels outside the page to 0..100 (Req 8.4)', () {
      // Above/left of the page clamps to 0; below/right clamps to 100.
      expect(geo.screenToPct(const Offset(-50, -90)), const Offset(0, 0));
      expect(geo.screenToPct(const Offset(2000, 5000)), const Offset(100, 100));
    });

    test('screenToPct returns 0 on a zero-size axis (web rect.width>0 guard)',
        () {
      final flat = CanvasGeometry(
        pageDisplaySize: const Size(0, 1000),
        zoom: 1.0,
      );
      final p = flat.screenToPct(const Offset(123, 500));
      expect(p.dx, 0.0); // zero-width axis -> 0
      expect(p.dy, 50.0); // healthy axis still maps
    });

    test('segToScreenRect maps a segment to a well-formed screen rect', () {
      const seg = QuestionSegment(
        page: 1,
        xStartPct: 10,
        xEndPct: 60,
        yStartPct: 20,
        yEndPct: 70,
      );
      final rect = geo.segToScreenRect(seg);
      expect(rect, const Rect.fromLTRB(80, 200, 480, 700));
      expect(rect.left, lessThanOrEqualTo(rect.right));
      expect(rect.top, lessThanOrEqualTo(rect.bottom));
    });

    test('fit-width=1.0 baseline; zoom scales the displayed page size', () {
      final g = CanvasGeometry.fromFitWidth(
        fitWidthSize: const Size(800, 1000),
        zoom: 2.0,
      );
      expect(g.zoom, 2.0);
      expect(g.pageDisplaySize, const Size(1600, 2000));
      // A page-percent point still maps proportionally at any zoom.
      expect(g.pctToScreen(50, 50), const Offset(800, 1000));
    });
  });

  group('Property 3 — coordinate fidelity (seeded property generator)', () {
    test(
        'round-trip screenToPct(pctToScreen(p)) == p within tolerance '
        'across zoom/pan', () {
      // **Validates: Requirements 8.1, 8.8**
      final base = 'rt-coord-fidelity'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(base + i);
        final g = _geometry(r);

        // An in-range point: both axes in 0..100 (the clamp is a no-op here, so
        // the round-trip must recover it exactly up to float error).
        final xPct = r.nextDouble() * 100.0;
        final yPct = r.nextDouble() * 100.0;

        final screen = g.pctToScreen(xPct, yPct);
        final back = g.screenToPct(screen);

        expect(
          back.dx,
          closeTo(xPct, _tol),
          reason: 'x round-trip drifted (iteration $i, seed ${base + i}, '
              'geometry $g).',
        );
        expect(
          back.dy,
          closeTo(yPct, _tol),
          reason: 'y round-trip drifted (iteration $i, seed ${base + i}, '
              'geometry $g).',
        );
      }
    });

    test('screenToPct always lands in 0..100 for ANY pixel (Req 8.4, 8.6)', () {
      // **Validates: Requirements 8.4, 8.6**
      final base = 'clamp-0-100'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(base + i);
        final g = _geometry(r);

        // Pointers anywhere on screen, deliberately including positions far
        // outside the page box (negative and beyond the displayed size) to
        // exercise the clamp — a drag can leave the page edge.
        final local = _wildScreenPoint(r, g);
        final p = g.screenToPct(local);

        expect(
          p.dx,
          inInclusiveRange(0.0, 100.0),
          reason: 'x escaped 0..100 (iteration $i, seed ${base + i}, '
              'local $local, geometry $g).',
        );
        expect(
          p.dy,
          inInclusiveRange(0.0, 100.0),
          reason: 'y escaped 0..100 (iteration $i, seed ${base + i}, '
              'local $local, geometry $g).',
        );
      }
    });

    test(
        'a box drawn / re-selected from two pointers has coords in 0..100 with '
        'end >= start across zoom/pan (Req 8.1, 8.4, 8.6)', () {
      // **Validates: Requirements 8.1, 8.4, 8.6**
      //
      // Models the canvas draw/re-select gesture: two pointer positions
      // (drag start + end) are each mapped through `screenToPct`, then the box
      // is the min/max of the two — exactly as the web canvas normalizes a
      // selection. The resulting stored segment must satisfy the engine
      // contract: every coordinate in 0..100 with end >= start.
      final base = 'draw-reselect-stored'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(base + i);
        final g = _geometry(r);

        final a = g.screenToPct(_wildScreenPoint(r, g));
        final b = g.screenToPct(_wildScreenPoint(r, g));

        final seg = QuestionSegment(
          page: 1,
          xStartPct: math.min(a.dx, b.dx),
          xEndPct: math.max(a.dx, b.dx),
          yStartPct: math.min(a.dy, b.dy),
          yEndPct: math.max(a.dy, b.dy),
        );

        for (final v in <double>[
          seg.xStartPct,
          seg.xEndPct,
          seg.yStartPct,
          seg.yEndPct,
        ]) {
          expect(
            v,
            inInclusiveRange(0.0, 100.0),
            reason: 'stored coord escaped 0..100 (iteration $i, '
                'seed ${base + i}, seg ${_segStr(seg)}, geometry $g).',
          );
        }
        expect(
          seg.xEndPct,
          greaterThanOrEqualTo(seg.xStartPct),
          reason: 'x end < start (iteration $i, seed ${base + i}, '
              'seg ${_segStr(seg)}).',
        );
        expect(
          seg.yEndPct,
          greaterThanOrEqualTo(seg.yStartPct),
          reason: 'y end < start (iteration $i, seed ${base + i}, '
              'seg ${_segStr(seg)}).',
        );
      }
    });
  });
}

// ===========================================================================
//  Seeded generators
// ===========================================================================

/// A signed value in [-mag, mag].
double _span(math.Random r, double mag) => (r.nextDouble() * 2.0 - 1.0) * mag;

/// A random, valid view snapshot: positive page size, full-range zoom, and a
/// wide pan offset. Built both directly and via the fit-width factory so both
/// construction paths are exercised.
CanvasGeometry _geometry(math.Random r) {
  final zoom = kZoomMin + r.nextDouble() * (kZoomMax - kZoomMin); // 0.25..6.0
  final pan = Offset(_span(r, 3000.0), _span(r, 3000.0));

  if (r.nextBool()) {
    // fit-width path: pageDisplaySize == fitWidthSize * zoom.
    final fitW = 50.0 + r.nextDouble() * 2950.0; // 50..3000
    final fitH = 50.0 + r.nextDouble() * 2950.0;
    return CanvasGeometry.fromFitWidth(
      fitWidthSize: Size(fitW, fitH),
      zoom: zoom,
      panOffset: pan,
    );
  }

  // direct path: an already-zoomed display size (kept strictly positive).
  final w = 50.0 + r.nextDouble() * 18000.0;
  final h = 50.0 + r.nextDouble() * 18000.0;
  return CanvasGeometry(pageDisplaySize: Size(w, h), zoom: zoom, panOffset: pan);
}

/// A pointer position anywhere on screen, intentionally biased to also fall
/// outside the displayed page box (negative and beyond the size + pan) so the
/// clamp in `screenToPct` is exercised — a user can drag past the page edge.
Offset _wildScreenPoint(math.Random r, CanvasGeometry g) {
  final w = g.pageDisplaySize.width;
  final h = g.pageDisplaySize.height;
  // Range spans roughly [-0.25, 1.25] of the page, then shifted by pan, so
  // many points land outside 0..page.
  final x = g.panOffset.dx + (-0.25 + r.nextDouble() * 1.5) * w;
  final y = g.panOffset.dy + (-0.25 + r.nextDouble() * 1.5) * h;
  return Offset(x, y);
}

String _segStr(QuestionSegment s) =>
    'x[${s.xStartPct}, ${s.xEndPct}] y[${s.yStartPct}, ${s.yEndPct}]';
