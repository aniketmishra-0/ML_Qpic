import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/review_canvas_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/models/analyze.dart';
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

AnalyzeResponse _analyze({
  String jobId = 'job-1',
  int answerKeyCount = 0,
  List<PageInfo>? pages,
  List<AnalyzedItem>? items,
  List<ReviewNote>? notes,
  bool needsReview = false,
}) =>
    AnalyzeResponse(
      jobId: jobId,
      totalPages: (pages ?? <PageInfo>[_page(1)]).length,
      methodUsed: 'text',
      pages: pages ?? <PageInfo>[_page(1)],
      items: items ?? <AnalyzedItem>[],
      notes: notes ?? <ReviewNote>[],
      needsReview: needsReview,
      answerKeyCount: answerKeyCount,
    );

void main() {
  group('loaded by both tools (Req 6.2)', () {
    test('loadFromAnalyze populates jobId, pages, items, notes, answer key', () {
      final c = ReviewController();
      addTearDown(c.dispose);

      c.loadFromAnalyze(_analyze(
        jobId: 'analyze-job',
        answerKeyCount: 12,
        pages: <PageInfo>[_page(1), _page(2)],
        items: <AnalyzedItem>[_item(qNum: '1'), _item(qNum: '2')],
        notes: <ReviewNote>[
          const ReviewNote(kind: 'gap', message: 'gap between 1 and 2'),
        ],
      ));

      expect(c.jobId, 'analyze-job');
      expect(c.source, ReviewSource.smartAutoCrop);
      expect(c.pages.length, 2);
      expect(c.items.length, 2);
      expect(c.notes.length, 1);
      expect(c.answerKeyCount, 12);
      expect(c.currentPageIndex, 0, reason: 'view resets to first page');
    });

    test('loadFromManual starts empty with no notes and no answer key', () {
      final c = ReviewController();
      addTearDown(c.dispose);

      c.loadFromManual(_analyze(
        jobId: 'manual-job',
        answerKeyCount: 9, // ignored for manual
        pages: <PageInfo>[_page(1), _page(2), _page(3)],
        items: <AnalyzedItem>[_item(qNum: '99')], // ignored for manual
        notes: <ReviewNote>[const ReviewNote(kind: 'tiny', message: 'x')],
      ));

      expect(c.jobId, 'manual-job');
      expect(c.source, ReviewSource.manualCrop);
      expect(c.pages.length, 3);
      expect(c.items, isEmpty, reason: 'manual crop starts with no items');
      expect(c.notes, isEmpty);
      expect(c.answerKeyCount, isNull);
    });

    test('the same canvas serves both tools (drawing works after either load)',
        () async {
      final c = ReviewController();
      addTearDown(c.dispose);

      c.loadFromManual(_analyze(pages: <PageInfo>[_page(1)]));
      final created =
          await c.commitDrawnSegment(_seg(x0: 5, x1: 50, y0: 5, y1: 50));
      expect(created, isTrue);
      expect(c.items.single.source, 'manual');
    });
  });

  group('answer-sheet messaging (Req 6.4/6.5)', () {
    test('answerKeyCount > 0 ⇒ finalize will include an answer sheet', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(answerKeyCount: 3));
      expect(c.finalizeWillIncludeAnswerSheet, isTrue);
      expect(c.state.finalizeWillIncludeAnswerSheet, isTrue);
    });

    test('answerKeyCount == 0 ⇒ finalize will NOT include an answer sheet', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(answerKeyCount: 0));
      expect(c.finalizeWillIncludeAnswerSheet, isFalse);
    });

    test('manual crop never includes an answer sheet', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromManual(_analyze());
      expect(c.finalizeWillIncludeAnswerSheet, isFalse);
    });
  });

  group('additive re-select (Req 8.6) + Done cleanup (Req 8.7)', () {
    test('startReselectForItem appends across pages and locks the item',
        () async {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(
        pages: <PageInfo>[_page(3), _page(4)],
        items: <AnalyzedItem>[
          _item(
            qNum: '5',
            flagged: true,
            source: 'auto',
            segments: <QuestionSegment>[_seg(page: 3, y0: 10, y1: 30)],
          ),
        ],
      ));

      c.startReselectForItem(0);
      expect(c.isEditing, isTrue);
      expect(c.currentPageNumber, 3, reason: 'jumps to the item first page');

      await c.commitDrawnSegment(_seg(page: 3, x0: 10, x1: 60, y0: 50, y1: 70));
      c.nextPage();
      await c.commitDrawnSegment(_seg(page: 4, x0: 10, x1: 60, y0: 10, y1: 30));

      expect(c.items.length, 1, reason: 'still one item — additive');
      expect(c.items.single.segments.length, 3);
      expect(c.items.single.source, 'manual');
      expect(c.items.single.flagged, isFalse);
    });

    test('Fix action on an incomplete note re-selects its item (Req 10.4)', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(
        pages: <PageInfo>[_page(1), _page(2)],
        items: <AnalyzedItem>[
          _item(qNum: '7', segments: <QuestionSegment>[_seg(page: 2)]),
        ],
        notes: <ReviewNote>[
          const ReviewNote(
            kind: 'incomplete',
            message: 'Q7 looks cut off',
            qNum: '7',
            page: 2,
          ),
        ],
      ));

      final note = c.notes.single;
      final started = c.startReselectForNote(note);
      expect(started, isTrue);
      expect(c.isEditing, isTrue);
      expect(c.currentPageNumber, 2, reason: 'navigates to the item page');
    });

    test('startReselectForNote returns false when no q_num / no match', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(items: <AnalyzedItem>[_item(qNum: '1')]));

      expect(
        c.startReselectForNote(
          const ReviewNote(kind: 'duplicate', message: 'm'),
        ),
        isFalse,
        reason: 'no q_num → no Fix target',
      );
      expect(
        c.startReselectForNote(
          const ReviewNote(kind: 'incomplete', message: 'm', qNum: '999'),
        ),
        isFalse,
        reason: 'no matching item',
      );
    });

    test('doneReselecting drops an item left with zero segments (Req 8.7)',
        () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[
          _item(qNum: '9', segments: <QuestionSegment>[_seg()]),
        ],
      ));

      c.startReselectForItem(0);
      c.deleteSegment(0, 0);
      expect(c.items.single.segments, isEmpty);

      c.doneReselecting();
      expect(c.items, isEmpty, reason: 'empty item dropped on Done');
      expect(c.isEditing, isFalse);
    });
  });

  group('page navigation clamps (Req 8.12) via the controller', () {
    test('gotoPageIndex / next / previous clamp to first..last', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromManual(_analyze(pages: <PageInfo>[_page(1), _page(2), _page(3)]));

      c.previousPage();
      expect(c.currentPageIndex, 0);
      c.gotoPageIndex(99);
      expect(c.currentPageIndex, 2);
      c.nextPage();
      expect(c.currentPageIndex, 2);
    });
  });

  group('finalize builder (Req 6.6/7.4 seam)', () {
    test('toFinalizeItems maps kept items and skips empty ones', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[
          _item(qNum: '1', segments: <QuestionSegment>[_seg()]),
          _item(qNum: '2', segments: const <QuestionSegment>[]),
        ],
      ));

      final items = c.toFinalizeItems();
      expect(items.length, 1, reason: 'zero-segment item skipped');
      expect(items.single.qNum, '1');
    });

    test('buildFinalizeRequest carries jobId, items and output config', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(
        jobId: 'fin-job',
        answerKeyCount: 5,
        items: <AnalyzedItem>[_item(qNum: '1')],
      ));

      final req = c.buildFinalizeRequest(
        questionPrefix: 'Question',
        startNumber: 3,
        imageFormat: 'jpg',
        jpgQuality: 80,
      );
      expect(req.jobId, 'fin-job');
      expect(req.items.length, 1);
      expect(req.questionPrefix, 'Question');
      expect(req.startNumber, 3);
      expect(req.imageFormat, 'jpg');
      expect(req.jpgQuality, 80);
      expect(req.answerSheet, isTrue,
          reason: 'defaults to detected answer key > 0');
    });

    test('answerSheet override wins over the detected default (Req 11.5)', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(answerKeyCount: 5));
      final req = c.buildFinalizeRequest(answerSheet: false);
      expect(req.answerSheet, isFalse);
    });
  });

  group('snap seam (task 12.2)', () {
    test('snapInterceptor forwards to the wrapped canvas controller', () async {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromManual(_analyze(pages: <PageInfo>[_page(1)]));

      c.snapInterceptor = (QuestionSegment drawn) async => QuestionSegment(
            page: drawn.page,
            xStartPct: drawn.xStartPct + 1,
            xEndPct: drawn.xEndPct - 1,
            yStartPct: drawn.yStartPct + 1,
            yEndPct: drawn.yEndPct - 1,
          );
      expect(identical(c.snapInterceptor, c.canvas.segmentInterceptor), isTrue);

      await c.commitDrawnSegment(_seg(x0: 10, x1: 50, y0: 10, y1: 50));
      expect(c.items.single.segments.single.xStartPct, 11);
      expect(c.items.single.segments.single.xEndPct, 49);
    });
  });

  group('state snapshot', () {
    test('state reflects the live session fields', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze(
        jobId: 'snap-job',
        answerKeyCount: 2,
        pages: <PageInfo>[_page(1), _page(2)],
        items: <AnalyzedItem>[_item()],
      ));
      c.nextPage();
      c.setZoom(2.0);
      c.canvas.panBy(const Offset(5, 7));

      final ReviewState s = c.state;
      expect(s.jobId, 'snap-job');
      expect(s.answerKeyCount, 2);
      expect(s.source, ReviewSource.smartAutoCrop);
      expect(s.pages.length, 2);
      expect(s.currentPageIndex, 1);
      expect(s.zoom, 2.0);
      expect(s.pan, const Offset(5, 7));
      expect(s.isEditing, isFalse);
    });

    test('empty snapshot is the documented default', () {
      expect(ReviewState.empty.jobId, '');
      expect(ReviewState.empty.pages, isEmpty);
      expect(ReviewState.empty.editingIndex, -1);
      expect(ReviewState.empty.finalizeWillIncludeAnswerSheet, isFalse);
    });
  });

  group('notifies listeners on session changes', () {
    test('load + canvas ops both notify', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      var notifications = 0;
      c.addListener(() => notifications++);

      c.loadFromAnalyze(_analyze(items: <AnalyzedItem>[_item()]));
      c.nextPage(); // single page → no change, but zoom will
      c.setZoom(3.0);

      expect(notifications, greaterThanOrEqualTo(2));
    });
  });

  group('wrapping does not break the canvas widget binding', () {
    test('a supplied canvas is shared, not disposed by default', () {
      final canvas = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
      final c = ReviewController(canvas: canvas);
      expect(identical(c.canvas, canvas), isTrue);

      c.dispose();
      // The shared canvas must still be usable (not disposed by the wrapper).
      expect(() => canvas.gotoPageIndex(0), returnsNormally);
      canvas.dispose();
    });
  });
}
