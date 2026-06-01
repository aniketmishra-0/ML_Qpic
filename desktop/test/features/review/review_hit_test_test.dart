import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/canvas_geometry.dart';
import 'package:qpic_desktop/features/review/review_hit_test.dart';
import 'package:qpic_desktop/models/crop.dart';

// Basic verification of the deterministic top-most hit-test used by the canvas
// input layer (Req 8.10). The exhaustive single-resolution property test lives
// in task 11.6; these are the focused examples that pin the contract.

CanvasGeometry _geometry() => CanvasGeometry(
      pageDisplaySize: const Size(1000, 1000),
      zoom: 1.0,
    );

AnalyzedItem _box({
  required String qNum,
  required double x0,
  required double x1,
  required double y0,
  required double y1,
  int page = 1,
}) =>
    AnalyzedItem(
      qNum: qNum,
      source: 'manual',
      segments: <QuestionSegment>[
        QuestionSegment(
          page: page,
          xStartPct: x0,
          xEndPct: x1,
          yStartPct: y0,
          yEndPct: y1,
        ),
      ],
    );

void main() {
  test('returns null when the point hits no box', () {
    final BoxHit? hit = hitTestTopMost(
      items: <AnalyzedItem>[_box(qNum: '1', x0: 10, x1: 20, y0: 10, y1: 20)],
      pageNumber: 1,
      geometry: _geometry(),
      localPoint: const Offset(900, 900), // 90%,90% — outside the box
    );
    expect(hit, isNull);
  });

  test('resolves a single containing box', () {
    final BoxHit? hit = hitTestTopMost(
      items: <AnalyzedItem>[_box(qNum: '1', x0: 10, x1: 50, y0: 10, y1: 50)],
      pageNumber: 1,
      geometry: _geometry(),
      localPoint: const Offset(300, 300), // 30%,30%
    );
    expect(hit, const BoxHit(0, 0));
  });

  test('overlapping boxes resolve to the LAST-drawn (top-most) one', () {
    final items = <AnalyzedItem>[
      _box(qNum: '1', x0: 10, x1: 60, y0: 10, y1: 60),
      _box(qNum: '2', x0: 20, x1: 70, y0: 20, y1: 70), // drawn later → on top
    ];
    final BoxHit? hit = hitTestTopMost(
      items: items,
      pageNumber: 1,
      geometry: _geometry(),
      localPoint: const Offset(400, 400), // 40%,40% — inside both
    );
    expect(hit, const BoxHit(1, 0), reason: 'higher index sits on top');
  });

  test('is deterministic for identical inputs', () {
    final items = <AnalyzedItem>[
      _box(qNum: '1', x0: 10, x1: 60, y0: 10, y1: 60),
      _box(qNum: '2', x0: 20, x1: 70, y0: 20, y1: 70),
      _box(qNum: '3', x0: 30, x1: 80, y0: 30, y1: 80),
    ];
    final geometry = _geometry();
    const point = Offset(400, 400);
    final BoxHit? first = hitTestTopMost(
      items: items,
      pageNumber: 1,
      geometry: geometry,
      localPoint: point,
    );
    for (var i = 0; i < 5; i++) {
      expect(
        hitTestTopMost(
          items: items,
          pageNumber: 1,
          geometry: geometry,
          localPoint: point,
        ),
        first,
      );
    }
  });

  test('ignores segments on other pages (Req 8.12)', () {
    final BoxHit? hit = hitTestTopMost(
      items: <AnalyzedItem>[
        _box(qNum: '1', x0: 10, x1: 60, y0: 10, y1: 60, page: 2),
      ],
      pageNumber: 1,
      geometry: _geometry(),
      localPoint: const Offset(300, 300),
    );
    expect(hit, isNull);
  });

  test('within an item, the last segment wins', () {
    const item = AnalyzedItem(
      qNum: '1',
      source: 'manual',
      segments: <QuestionSegment>[
        QuestionSegment(page: 1, xStartPct: 10, xEndPct: 60, yStartPct: 10, yEndPct: 60),
        QuestionSegment(page: 1, xStartPct: 20, xEndPct: 70, yStartPct: 20, yEndPct: 70),
      ],
    );
    final BoxHit? hit = hitTestTopMost(
      items: <AnalyzedItem>[item],
      pageNumber: 1,
      geometry: _geometry(),
      localPoint: const Offset(400, 400),
    );
    expect(hit, const BoxHit(0, 1));
  });
}
