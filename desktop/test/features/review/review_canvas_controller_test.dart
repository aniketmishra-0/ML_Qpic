import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/canvas_geometry.dart';
import 'package:qpic_desktop/features/review/review_canvas_controller.dart';
import 'package:qpic_desktop/models/crop.dart';

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '/api/preview/$n.png',
    );

QuestionSegment _seg({
  int page = 1,
  double x0 = 10,
  double x1 = 40,
  double y0 = 10,
  double y1 = 40,
}) =>
    QuestionSegment(
      page: page,
      xStartPct: x0,
      xEndPct: x1,
      yStartPct: y0,
      yEndPct: y1,
    );

AnalyzedItem _item({
  String qNum = '1',
  bool isSolution = false,
  bool flagged = false,
  String source = 'auto',
  List<QuestionSegment>? segments,
}) =>
    AnalyzedItem(
      qNum: qNum,
      isSolution: isSolution,
      flagged: flagged,
      source: source,
      segments: segments ?? <QuestionSegment>[_seg()],
    );

void main() {
  group('page navigation clamps to first..last (Req 8.12)', () {
    test('previous/next stop at the ends', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1), _page(2), _page(3)],
      );
      expect(c.currentPageIndex, 0);
      expect(c.isFirstPage, isTrue);

      c.previousPage();
      expect(c.currentPageIndex, 0, reason: 'clamped at first page');

      c.nextPage();
      c.nextPage();
      expect(c.currentPageIndex, 2);
      expect(c.isLastPage, isTrue);

      c.nextPage();
      expect(c.currentPageIndex, 2, reason: 'clamped at last page');
    });

    test('gotoPageIndex clamps out-of-range targets', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1), _page(2)]);
      c.gotoPageIndex(99);
      expect(c.currentPageIndex, 1);
      c.gotoPageIndex(-5);
      expect(c.currentPageIndex, 0);
    });

    test('currentPageNumber reflects the absolute page number', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(5), _page(6)]);
      expect(c.currentPageNumber, 5);
      c.nextPage();
      expect(c.currentPageNumber, 6);
    });
  });

  group('zoom clamps to 0.25..6.0 (Req 8.9)', () {
    test('setZoom clamps below and above the range', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      c.setZoom(0.01);
      expect(c.zoom, kZoomMin);
      c.setZoom(99);
      expect(c.zoom, kZoomMax);
    });

    test('zoomBy stays within bounds', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)], zoom: 1.0);
      for (var i = 0; i < 50; i++) {
        c.zoomBy(1.25);
      }
      expect(c.zoom, lessThanOrEqualTo(kZoomMax));
      for (var i = 0; i < 100; i++) {
        c.zoomBy(0.8);
      }
      expect(c.zoom, greaterThanOrEqualTo(kZoomMin));
    });

    test('resetZoom returns to fit-width (1.0)', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)], zoom: 3.0);
      c.resetZoom();
      expect(c.zoom, kFitWidthZoom);
    });
  });

  group('pan translates panOffset only, never pct (Req 8.8)', () {
    test('panBy changes offset but leaves box coordinates untouched', () {
      final QuestionSegment original = _seg(x0: 12, x1: 48, y0: 20, y1: 55);
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[_item(segments: <QuestionSegment>[original])],
      );
      c.panBy(const Offset(30, -45));
      expect(c.panOffset, const Offset(30, -45));

      final QuestionSegment after = c.items.first.segments.first;
      expect(after.xStartPct, original.xStartPct);
      expect(after.xEndPct, original.xEndPct);
      expect(after.yStartPct, original.yStartPct);
      expect(after.yEndPct, original.yEndPct);
    });

    test('zoom does not mutate box coordinates either', () {
      final QuestionSegment original = _seg();
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[_item(segments: <QuestionSegment>[original])],
      );
      c.setZoom(4.0);
      final QuestionSegment after = c.items.first.segments.first;
      expect(after.xStartPct, original.xStartPct);
      expect(after.yEndPct, original.yEndPct);
    });
  });

  group('drawing a box (Req 8.4, 8.5)', () {
    test('commits a valid drawn segment as a new manual item', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      final bool created =
          c.commitSegmentSync(_seg(x0: 5, x1: 50, y0: 5, y1: 50));
      expect(created, isTrue);
      expect(c.items.length, 1);
      expect(c.items.first.source, 'manual');
      expect(c.items.first.qNum, '1');
    });

    test('discards a drag below 1.5% of page width or height (Req 8.5)', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      // Width 1.0% < 1.5% → discarded.
      final bool created =
          c.commitSegmentSync(_seg(x0: 10, x1: 11, y0: 10, y1: 40));
      expect(created, isFalse);
      expect(c.items, isEmpty);
    });

    test('auto-numbers per type as max same-type + 1 (Req 8.13)', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[
          _item(qNum: '3'),
          _item(qNum: '7'),
        ],
      );
      c.commitSegmentSync(_seg(x0: 60, x1: 90, y0: 60, y1: 90));
      expect(c.items.last.qNum, '8');
    });

    test('solution numbering is independent of questions (Req 8.13)', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      c.setDrawAsSolution(true);
      c.commitSegmentSync(_seg(x0: 5, x1: 50, y0: 5, y1: 50));
      expect(c.items.single.isSolution, isTrue);
      expect(c.items.single.qNum, '1');
    });

    test('explicit pending number wins and is consumed', () {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      c.setPendingNumber('42');
      c.commitSegmentSync(_seg(x0: 5, x1: 50, y0: 5, y1: 50));
      expect(c.items.single.qNum, '42');
      expect(c.pendingNumber, '');
    });
  });

  group('overlap → replace not duplicate (Req 8.11)', () {
    test('a same-type box at IoU >= 0.6 replaces and keeps the number', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[
          _item(qNum: '3', segments: <QuestionSegment>[
            _seg(x0: 10, x1: 50, y0: 10, y1: 50),
          ]),
        ],
      );
      // Nearly the same rect → high IoU → replace, not add.
      c.commitSegmentSync(_seg(x0: 11, x1: 51, y0: 11, y1: 51));
      expect(c.items.length, 1, reason: 'replaced, not duplicated');
      expect(c.items.single.qNum, '3', reason: 'number preserved');
      expect(c.items.single.source, 'manual');
    });
  });

  group('additive re-select (Req 8.6)', () {
    test('appends drawn boxes to the editing item across pages', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(3), _page(4)],
        items: <AnalyzedItem>[
          _item(
            qNum: '5',
            flagged: true,
            source: 'auto',
            segments: <QuestionSegment>[_seg(page: 3, y0: 10, y1: 30)],
          ),
        ],
      );
      c.startEditing(0);
      // startEditing jumps to the item's first page (page 3).
      expect(c.currentPageNumber, 3);
      expect(c.isEditing, isTrue);

      // Draw a second part on page 3.
      c.commitSegmentSync(_seg(page: 3, x0: 10, x1: 60, y0: 50, y1: 70));
      // Move to page 4 and append a third part.
      c.nextPage();
      c.commitSegmentSync(_seg(page: 4, x0: 10, x1: 60, y0: 10, y1: 30));

      expect(c.items.length, 1, reason: 'still one item — additive');
      expect(c.items.single.segments.length, 3);
      expect(c.items.single.source, 'manual');
      expect(c.items.single.flagged, isFalse);
    });

    test('re-select clears a matching review note (Fix semantics)', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[_item(qNum: '5')],
        notes: <ReviewNote>[
          const ReviewNote(
            kind: 'incomplete',
            message: 'Q5 looks cut off',
            qNum: '5',
          ),
        ],
      );
      c.startEditing(0);
      c.commitSegmentSync(_seg(x0: 5, x1: 60, y0: 5, y1: 60));
      expect(c.notes, isEmpty, reason: 'matching note removed on fix');
    });

    test('done drops an item left with zero segments (Req 8.7)', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[
          _item(qNum: '9', segments: <QuestionSegment>[_seg()]),
        ],
      );
      c.startEditing(0);
      c.deleteSegment(0, 0);
      expect(c.items.single.segments, isEmpty);
      c.stopEditing();
      expect(c.items, isEmpty, reason: 'empty item dropped on Done');
      expect(c.isEditing, isFalse);
    });
  });

  group('delete (Req 8.7)', () {
    test('deleteSegment removes one box but keeps the item', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[
          _item(segments: <QuestionSegment>[
            _seg(y0: 10, y1: 30),
            _seg(y0: 40, y1: 60),
          ]),
        ],
      );
      c.deleteSegment(0, 0);
      expect(c.items.single.segments.length, 1);
      expect(c.items.single.segments.first.yStartPct, 40);
    });

    test('deleteItem removes the whole item', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[_item(qNum: '1'), _item(qNum: '2')],
      );
      c.deleteItem(0);
      expect(c.items.length, 1);
      expect(c.items.single.qNum, '2');
    });
  });

  group('hover shows the q-number (Req 8.3)', () {
    test('hovering a box sets the hovered label; exit clears it', () {
      final c = ReviewCanvasController(
        pages: <PageInfo>[_page(1)],
        items: <AnalyzedItem>[
          _item(qNum: '7', segments: <QuestionSegment>[
            _seg(x0: 10, x1: 50, y0: 10, y1: 50),
          ]),
        ],
      );
      final geometry = CanvasGeometry(
        pageDisplaySize: const Size(1000, 1000),
        zoom: 1.0,
      );
      // Point at 20%,20% → inside the box (100..500 px).
      c.updateHover(const Offset(200, 200), geometry);
      expect(c.hoveredItemIndex, 0);
      expect(c.hoveredLabel, '7');

      c.updateHover(null, geometry);
      expect(c.hoveredItemIndex, -1);
      expect(c.hoveredLabel, isNull);
    });
  });

  group('snap seam (segmentInterceptor)', () {
    test('drawn segment is passed through the interceptor before commit', () async {
      final c = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      c.segmentInterceptor = (QuestionSegment drawn) async {
        // Pretend the engine tightened the box.
        return QuestionSegment(
          page: drawn.page,
          xStartPct: drawn.xStartPct + 1,
          xEndPct: drawn.xEndPct - 1,
          yStartPct: drawn.yStartPct + 1,
          yEndPct: drawn.yEndPct - 1,
        );
      };
      await c.commitDrawnSegment(_seg(x0: 10, x1: 50, y0: 10, y1: 50));
      expect(c.items.single.segments.single.xStartPct, 11);
      expect(c.items.single.segments.single.xEndPct, 49);
    });
  });
}
