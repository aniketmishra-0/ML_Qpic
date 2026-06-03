import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/features/review/review_items_panel.dart';
import 'package:qpic_desktop/features/review/review_notes_panel.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '/api/preview/$n.png',
    );

QuestionSegment _seg({int page = 1}) => QuestionSegment(
      page: page,
      xStartPct: 10,
      xEndPct: 40,
      yStartPct: 10,
      yEndPct: 40,
    );

AnalyzedItem _item({
      required String qNum,
      bool isSolution = false,
      bool flagged = false,
      int page = 1,
    }) =>
        AnalyzedItem(
          qNum: qNum,
          isSolution: isSolution,
          flagged: flagged,
          segments: <QuestionSegment>[_seg(page: page)],
        );

ReviewNote _note({
  required String kind,
  required String message,
  String? qNum,
  bool isSolution = false,
}) =>
    ReviewNote(
      kind: kind,
      message: message,
      qNum: qNum,
      isSolution: isSolution,
    );

AnalyzeResponse _analyze({
  required List<AnalyzedItem> items,
  required List<ReviewNote> notes,
}) =>
    AnalyzeResponse(
      jobId: 'job-1',
      totalPages: 1,
      methodUsed: 'text',
      pages: <PageInfo>[_page(1)],
      items: items,
      notes: notes,
      needsReview: false,
    );

void main() {
  testWidgets('ReviewNotesPanel filtering test', (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[],
        notes: <ReviewNote>[
          _note(kind: 'duplicate', message: 'Possible duplicate of Q3', qNum: '3'),
          _note(kind: 'incomplete', message: 'Q5 looks cut off', qNum: '5'),
        ],
      ));
    addTearDown(controller.dispose);

    // Initial state (no filter) -> both notes should show up
    await tester.pumpWidget(MaterialApp(
      theme: QpicTheme.light,
      home: Scaffold(
        body: ReviewNotesPanel(controller: controller),
      ),
    ));

    expect(find.text('Possible duplicate of Q3'), findsOneWidget);
    expect(find.text('Q5 looks cut off'), findsOneWidget);

    // Filter by "Q5" -> only Q5 note should show up
    await tester.pumpWidget(MaterialApp(
      theme: QpicTheme.light,
      home: Scaffold(
        body: ReviewNotesPanel(controller: controller, searchQuery: 'Q5'),
      ),
    ));

    expect(find.text('Possible duplicate of Q3'), findsNothing);
    expect(find.text('Q5 looks cut off'), findsOneWidget);
  });

  testWidgets('ReviewItemsPanel filtering test', (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[
          _item(qNum: '3', page: 1),
          _item(qNum: '5', page: 2, isSolution: true),
        ],
        notes: <ReviewNote>[],
      ));
    addTearDown(controller.dispose);

    // Initial state (no filter) -> both items show up
    await tester.pumpWidget(MaterialApp(
      theme: QpicTheme.light,
      home: Scaffold(
        body: ReviewItemsPanel(controller: controller),
      ),
    ));

    expect(find.text('Q3'), findsOneWidget);
    expect(find.text('S5'), findsOneWidget);

    // Filter by "S5" -> only S5 shows up
    await tester.pumpWidget(MaterialApp(
      theme: QpicTheme.light,
      home: Scaffold(
        body: ReviewItemsPanel(controller: controller, searchQuery: 'S5'),
      ),
    ));

    expect(find.text('Q3'), findsNothing);
    expect(find.text('S5'), findsOneWidget);
  });

  testWidgets('ReviewItemsPanel delete confirmation flow', (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[
          _item(qNum: '3', page: 1),
        ],
        notes: <ReviewNote>[],
      ));
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: QpicTheme.light,
      home: Scaffold(
        body: ReviewItemsPanel(controller: controller),
      ),
    ));

    expect(find.text('Q3'), findsOneWidget);

    // Tap delete button (X icon) on item Q3
    final deleteButton = find.byKey(const ValueKey<String>('review-item-delete-0'));
    expect(deleteButton, findsOneWidget);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // Confirm dialog is shown
    expect(find.text('Confirm Delete'), findsOneWidget);
    expect(find.text('Are you sure you want to delete Question no. Q3?'), findsOneWidget);

    // Click cancel
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Item should still be present in the panel and controller
    expect(find.text('Q3'), findsOneWidget);
    expect(controller.items.length, 1);

    // Tap delete button again
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // Click delete in the dialog
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // Item should be deleted
    expect(find.text('Q3'), findsNothing);
    expect(controller.items.isEmpty, true);
  });
}
