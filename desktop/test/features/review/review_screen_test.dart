// Widget tests for the ReviewScreen host (Task 12.5 — Requirements 6.2, 6.3,
// 6.4, 6.5).
//
// ReviewScreen is the surface the Smart Auto Crop flow opens after a successful
// analyze. These verify:
//   * the canvas is shown populated from the loaded session (6.2),
//   * the answer-sheet advisory tells the user the finalized output WILL
//     include an answer sheet when `answer_key_count > 0` (6.4) and will NOT
//     when it is 0 (6.5),
//   * a Manual Crop session (no answer key) shows no advisory,
//   * the notes panel renders the engine's notes (Req 10 surfaced here),
//   * page navigation through the toolbar works (the controller clamps).
//
// Network image loading is avoided by leaving previewUrl resolution to the
// default and using empty preview URLs (the painter simply draws no image),
// matching the existing review_canvas_test convention.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/features/review/review_screen.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '', // empty → no network fetch in the test
    );

AnalyzedItem _item(String qNum) => AnalyzedItem(
      qNum: qNum,
      source: 'auto',
      segments: const <QuestionSegment>[
        QuestionSegment(
          page: 1,
          xStartPct: 10,
          xEndPct: 50,
          yStartPct: 10,
          yEndPct: 50,
        ),
      ],
    );

AnalyzeResponse _analyze({
  int answerKeyCount = 0,
  List<PageInfo>? pages,
  List<AnalyzedItem>? items,
  List<ReviewNote>? notes,
  bool needsReview = false,
}) =>
    AnalyzeResponse(
      jobId: 'job-1',
      totalPages: (pages ?? <PageInfo>[_page(1)]).length,
      methodUsed: 'text',
      pages: pages ?? <PageInfo>[_page(1)],
      items: items ?? <AnalyzedItem>[_item('1')],
      notes: notes ?? <ReviewNote>[],
      needsReview: needsReview,
      answerKeyCount: answerKeyCount,
    );

Future<ReviewController> _pumpSmart(
  WidgetTester tester,
  AnalyzeResponse analysis, {
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = ReviewController();
  addTearDown(controller.dispose);
  controller.loadFromAnalyze(analysis);

  await tester.pumpWidget(
    MaterialApp(
      theme: QpicTheme.dark,
      home: ReviewScreen(controller: controller, onClose: onClose),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('shows the canvas populated from the loaded session (Req 6.2)',
      (tester) async {
    await _pumpSmart(tester, _analyze(needsReview: false));

    expect(find.byKey(const ValueKey('review-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-title')), findsOneWidget);
  });

  testWidgets('answer_key_count > 0 ⇒ WILL include an answer sheet (Req 6.4)',
      (tester) async {
    await _pumpSmart(tester, _analyze(answerKeyCount: 5));

    expect(
      find.byKey(const ValueKey('review-answer-sheet-advisory')),
      findsOneWidget,
    );
    final Text message = tester.widget(
      find.byKey(const ValueKey('review-answer-sheet-message')),
    );
    expect(message.data, contains('WILL include'));
    expect(message.data, contains('5 answers'));
  });

  testWidgets('answer_key_count == 0 ⇒ will NOT include an answer sheet (Req 6.5)',
      (tester) async {
    await _pumpSmart(tester, _analyze(answerKeyCount: 0));

    final Text message = tester.widget(
      find.byKey(const ValueKey('review-answer-sheet-message')),
    );
    expect(message.data, contains('NOT include'));
  });

  testWidgets('Manual Crop session (no answer key) shows no advisory',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ReviewController();
    addTearDown(controller.dispose);
    controller.loadFromManual(_analyze(pages: <PageInfo>[_page(1)]));

    await tester.pumpWidget(
      MaterialApp(
        theme: QpicTheme.dark,
        home: ReviewScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('review-answer-sheet-advisory')),
      findsNothing,
    );
  });

  testWidgets('renders the engine review notes (Req 10)', (tester) async {
    await _pumpSmart(
      tester,
      _analyze(
        notes: <ReviewNote>[
          const ReviewNote(kind: 'gap', message: 'Gap between Q1 and Q2'),
        ],
      ),
    );

    expect(find.byKey(const ValueKey('review-notes-panel')), findsOneWidget);
    expect(find.text('Gap between Q1 and Q2'), findsOneWidget);
  });

  testWidgets('toolbar page navigation moves through pages (Req 8.12)',
      (tester) async {
    final controller = await _pumpSmart(
      tester,
      _analyze(pages: <PageInfo>[_page(1), _page(2), _page(3)]),
    );

    expect(controller.currentPageNumber, 1);
    await tester.tap(find.byKey(const ValueKey('review-next-page')));
    await tester.pump();
    expect(controller.currentPageNumber, 2);
  });

  testWidgets('Back affordance invokes onClose', (tester) async {
    var closed = false;
    await _pumpSmart(
      tester,
      _analyze(),
      onClose: () => closed = true,
    );

    await tester.tap(find.byKey(const ValueKey('review-back')));
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('renders the Auto Detect button and dropdown menu options', (tester) async {
    final controller = await _pumpSmart(tester, _analyze());

    // Initially should show the Auto Detect button
    expect(find.byKey(const ValueKey('review-auto-detect-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-auto-detect-busy')), findsNothing);

    // Tap it to open the menu
    await tester.tap(find.byKey(const ValueKey('review-auto-detect-menu')));
    await tester.pumpAndSettle();

    // Verify popup menu items are shown
    expect(find.byKey(const ValueKey('review-auto-detect-use-ai')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-auto-detect-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-auto-detect-all')), findsOneWidget);
  });
}
