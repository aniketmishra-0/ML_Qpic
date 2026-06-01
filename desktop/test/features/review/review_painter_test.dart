import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/review/canvas_geometry.dart';
import 'package:qpic_desktop/features/review/review_painter.dart';
import 'package:qpic_desktop/models/crop.dart';

ReviewPainter _painter({
  required List<AnalyzedItem> items,
  int pageNumber = 1,
  int editingIndex = -1,
  int hoveredIndex = -1,
  QuestionSegment? selection,
  ui.Image? pageImage,
  int revision = 0,
  CanvasGeometry? geometry,
}) {
  return ReviewPainter(
    geometry: geometry ??
        CanvasGeometry(
          pageDisplaySize: const Size(800, 1000),
          zoom: 1.0,
        ),
    palette: QpicPalette.dark,
    items: items,
    pageNumber: pageNumber,
    editingIndex: editingIndex,
    hoveredIndex: hoveredIndex,
    selection: selection,
    pageImage: pageImage,
    revision: revision,
  );
}

AnalyzedItem _item({
  String qNum = '1',
  bool isSolution = false,
  bool flagged = false,
  List<QuestionSegment>? segments,
}) {
  return AnalyzedItem(
    qNum: qNum,
    isSolution: isSolution,
    flagged: flagged,
    segments: segments ??
        const <QuestionSegment>[
          QuestionSegment(page: 1, yStartPct: 10, yEndPct: 30),
        ],
  );
}

/// Runs the painter against a real recording canvas. Throws if `paint` does.
void _paintOnce(ReviewPainter painter, [Size size = const Size(800, 1000)]) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, size);
  recorder.endRecording().dispose();
}

void main() {
  group('ReviewPainter.handleCenter', () {
    const rect = Rect.fromLTWH(100, 200, 80, 40); // l=100,t=200,r=180,b=240

    test('maps the four corners', () {
      expect(ReviewPainter.handleCenter(rect, HandlePosition.nw),
          const Offset(100, 200));
      expect(ReviewPainter.handleCenter(rect, HandlePosition.ne),
          const Offset(180, 200));
      expect(ReviewPainter.handleCenter(rect, HandlePosition.sw),
          const Offset(100, 240));
      expect(ReviewPainter.handleCenter(rect, HandlePosition.se),
          const Offset(180, 240));
    });

    test('maps the four edge midpoints', () {
      expect(ReviewPainter.handleCenter(rect, HandlePosition.n),
          const Offset(140, 200));
      expect(ReviewPainter.handleCenter(rect, HandlePosition.s),
          const Offset(140, 240));
      expect(ReviewPainter.handleCenter(rect, HandlePosition.w),
          const Offset(100, 220));
      expect(ReviewPainter.handleCenter(rect, HandlePosition.e),
          const Offset(180, 220));
    });

    test('hit rect is centered on the handle and grabbable', () {
      final hit = ReviewPainter.handleHitRect(rect, HandlePosition.nw);
      expect(hit.center, const Offset(100, 200));
      expect(hit.contains(const Offset(100, 200)), isTrue);
      // A near-corner point lands inside the handle's hit area.
      expect(hit.contains(const Offset(104, 196)), isTrue);
    });
  });

  group('ReviewPainter.deleteAffordance', () {
    const rect = Rect.fromLTWH(100, 200, 80, 40);

    test('sits just outside the top-right corner', () {
      final center = ReviewPainter.deleteAffordanceCenter(rect);
      // Horizontally on the right edge, vertically ABOVE the top edge.
      expect(center.dx, rect.right);
      expect(center.dy, lessThan(rect.top));
    });

    test('hit rect contains its center', () {
      final hit = ReviewPainter.deleteAffordanceHitRect(rect);
      expect(hit.contains(ReviewPainter.deleteAffordanceCenter(rect)), isTrue);
    });
  });

  group('ReviewPainter.shouldRepaint', () {
    test('repaints when the revision changes', () {
      final a = _painter(items: [_item()], revision: 1);
      final b = _painter(items: a.items, revision: 2);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('does not repaint when nothing relevant changed', () {
      final items = [_item()];
      final geometry = CanvasGeometry(
        pageDisplaySize: const Size(800, 1000),
        zoom: 1.0,
      );
      final a = _painter(items: items, geometry: geometry, revision: 5);
      final b = _painter(items: items, geometry: geometry, revision: 5);
      expect(b.shouldRepaint(a), isFalse);
    });

    test('repaints on zoom / pan / page / edit / hover / selection change', () {
      final items = [_item()];
      final base = _painter(items: items, revision: 5);

      final zoomed = _painter(
        items: items,
        revision: 5,
        geometry: CanvasGeometry(
          pageDisplaySize: const Size(1600, 2000),
          zoom: 2.0,
        ),
      );
      expect(zoomed.shouldRepaint(base), isTrue);

      final panned = _painter(
        items: items,
        revision: 5,
        geometry: CanvasGeometry(
          pageDisplaySize: const Size(800, 1000),
          zoom: 1.0,
          panOffset: const Offset(10, 20),
        ),
      );
      expect(panned.shouldRepaint(base), isTrue);

      expect(_painter(items: items, revision: 5, pageNumber: 2)
          .shouldRepaint(base), isTrue);
      expect(_painter(items: items, revision: 5, editingIndex: 0)
          .shouldRepaint(base), isTrue);
      expect(_painter(items: items, revision: 5, hoveredIndex: 0)
          .shouldRepaint(base), isTrue);
      expect(
        _painter(
          items: items,
          revision: 5,
          selection:
              const QuestionSegment(page: 1, yStartPct: 5, yEndPct: 9),
        ).shouldRepaint(base),
        isTrue,
      );
    });
  });

  group('ReviewPainter.paint (smoke)', () {
    test('paints overlays with no decoded image (image still loading)', () {
      _paintOnce(_painter(items: [_item(), _item(qNum: '2', flagged: true)]));
    });

    test('paints the editing item with handles + delete affordance', () {
      _paintOnce(_painter(items: [_item()], editingIndex: 0));
    });

    test('paints the in-progress selection rectangle', () {
      _paintOnce(
        _painter(
          items: const <AnalyzedItem>[],
          selection:
              const QuestionSegment(page: 1, yStartPct: 5, yEndPct: 40),
        ),
      );
    });

    test('skips boxes whose segment is on another page (Req 8.12/8.2)', () {
      final offPage = _item(
        segments: const <QuestionSegment>[
          QuestionSegment(page: 2, yStartPct: 10, yEndPct: 30),
        ],
      );
      // Painting must not throw even though nothing on this page draws.
      _paintOnce(_painter(items: [offPage], pageNumber: 1));
    });

    test('labels a multi-segment item without throwing', () {
      final multi = _item(
        segments: const <QuestionSegment>[
          QuestionSegment(page: 1, yStartPct: 5, yEndPct: 20),
          QuestionSegment(page: 1, yStartPct: 50, yEndPct: 70),
        ],
      );
      _paintOnce(_painter(items: [multi]));
    });

    testWidgets('paints a decoded server-rendered image', (tester) async {
      // A 2x2 image stands in for the engine's preview PNG; the painter only
      // blits it (Req 1.5/6.3 — no Dart PDF rasterization).
      final image = await _solidImage(2, 2);
      addTearDown(image.dispose);
      _paintOnce(_painter(items: [_item()], pageImage: image));
    });
  });
}

Future<ui.Image> _solidImage(int w, int h) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(w, h);
}
