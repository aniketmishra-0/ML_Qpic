// Widget tests for ReviewNotesPanel (Task 12.4 — Requirement 10).
//
// These confirm the panel:
//   * renders each note's kind + message (10.1),
//   * shows the "detection looks complete" advisory on an empty notes list
//     (10.2),
//   * shows a Fix action ONLY for an `incomplete` note carrying a `q_num`
//     (10.3),
//   * navigates to the referenced item's page and enters re-select when Fix is
//     activated (10.4), and
//   * visually distinguishes all five note kinds via per-kind accent colors +
//     icons (10.5).
//
// No engine/network is used: the panel reads notes straight from a
// ReviewController seeded by loadFromAnalyze().

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
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
  String qNum = '1',
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
  String message = 'note message',
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
  List<PageInfo>? pages,
  List<AnalyzedItem>? items,
  List<ReviewNote>? notes,
}) =>
    AnalyzeResponse(
      jobId: 'job-1',
      totalPages: (pages ?? <PageInfo>[_page(1)]).length,
      methodUsed: 'text',
      pages: pages ?? <PageInfo>[_page(1)],
      items: items ?? <AnalyzedItem>[],
      notes: notes ?? <ReviewNote>[],
      needsReview: false,
    );

Widget _host(ReviewController controller) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ReviewNotesPanel(controller: controller),
      ),
    ),
  );
}

void main() {
  testWidgets('empty notes list shows the "detection looks complete" advisory '
      '(10.2)', (tester) async {
    final controller = ReviewController()..loadFromAnalyze(_analyze());
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    expect(
      find.byKey(const ValueKey<String>('review-notes-advisory')),
      findsOneWidget,
    );
    expect(find.textContaining('Detection looks complete'), findsOneWidget);
    // No "Items to Fix" header when there are no notes.
    expect(
      find.byKey(const ValueKey<String>('review-notes-head')),
      findsNothing,
    );
  });

  testWidgets('renders each note\'s kind + message (10.1) with a count header',
      (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        notes: <ReviewNote>[
          _note(kind: 'duplicate', message: 'Possible duplicate of Q3'),
          _note(kind: 'gap', message: 'Gap between Q4 and Q6'),
        ],
      ));
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    // Header + count reflect the number of notes.
    expect(
      find.byKey(const ValueKey<String>('review-notes-head')),
      findsOneWidget,
    );
    expect(find.text('Items to Fix'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // Each note's message is rendered.
    expect(find.text('Possible duplicate of Q3'), findsOneWidget);
    expect(find.text('Gap between Q4 and Q6'), findsOneWidget);

    // One row per note.
    expect(find.byKey(const ValueKey<String>('review-note-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('review-note-1')), findsOneWidget);
  });

  testWidgets('Fix action shows ONLY for an incomplete note with a q_num '
      '(10.3)', (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[_item(qNum: '5', flagged: true)],
        notes: <ReviewNote>[
          // incomplete + q_num → Fix.
          _note(kind: 'incomplete', message: 'Q5 looks cut off', qNum: '5'),
          // incomplete WITHOUT q_num → no Fix.
          _note(kind: 'incomplete', message: 'Something looks cut off'),
          // non-incomplete → no Fix even if it had a q_num.
          _note(kind: 'tiny', message: 'Tiny crop', qNum: '9'),
        ],
      ));
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    // Exactly one Fix button overall, and it belongs to the q_num=5 note.
    expect(find.widgetWithText(InkWell, 'Fix'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('review-note-fix-5')),
      findsOneWidget,
    );
  });

  testWidgets('activating Fix navigates to the item page and enters re-select '
      '(10.4)', (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        pages: <PageInfo>[_page(1), _page(2), _page(3)],
        // The flagged item lives on page 3.
        items: <AnalyzedItem>[_item(qNum: '7', flagged: true, page: 3)],
        notes: <ReviewNote>[
          _note(kind: 'incomplete', message: 'Q7 cut off', qNum: '7'),
        ],
      ));
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    // Precondition: not editing, viewing the first page.
    expect(controller.isEditing, isFalse);
    expect(controller.currentPageNumber, 1);

    await tester.tap(find.byKey(const ValueKey<String>('review-note-fix-7')));
    await tester.pump();

    // Re-select started on the matching item, and the canvas jumped to its
    // page (page 3, index 2).
    expect(controller.isEditing, isTrue);
    expect(controller.editingIndex, 0);
    expect(controller.currentPageNumber, 3);
  });

  testWidgets('distinguishes all five kinds with distinct accent colors + '
      'icons (10.5)', (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[_item(qNum: '1', flagged: true)],
        notes: <ReviewNote>[
          _note(kind: 'duplicate', message: 'duplicate note'),
          _note(kind: 'gap', message: 'gap note'),
          _note(kind: 'tiny', message: 'tiny note'),
          _note(kind: 'incomplete', message: 'incomplete note', qNum: '1'),
          _note(kind: 'low_confidence', message: 'low confidence note'),
        ],
      ));
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    const palette = QpicPalette.light;
    Color iconColorAt(int index) {
      final iconFinder = find.descendant(
        of: find.byKey(ValueKey<String>('review-note-$index')),
        matching: find.byType(Icon),
      );
      return tester.widget<Icon>(iconFinder).color!;
    }

    IconData iconDataAt(int index) {
      final iconFinder = find.descendant(
        of: find.byKey(ValueKey<String>('review-note-$index')),
        matching: find.byType(Icon),
      );
      return tester.widget<Icon>(iconFinder).icon!;
    }

    // Color mapping mirrors the web CSS: gap→accent, incomplete→danger,
    // others→warn.
    expect(iconColorAt(0), palette.noteDefault); // duplicate
    expect(iconColorAt(1), palette.noteGap); // gap
    expect(iconColorAt(2), palette.noteDefault); // tiny
    expect(iconColorAt(3), palette.noteIncomplete); // incomplete
    expect(iconColorAt(4), palette.noteDefault); // low_confidence

    // All five icons are distinct so the kinds read apart at a glance.
    final icons = <IconData>{
      iconDataAt(0),
      iconDataAt(1),
      iconDataAt(2),
      iconDataAt(3),
      iconDataAt(4),
    };
    expect(icons.length, 5);
  });

  testWidgets('re-renders when a note is resolved (notes list shrinks)',
      (tester) async {
    final controller = ReviewController()
      ..loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[_item(qNum: '2', flagged: true)],
        notes: <ReviewNote>[
          _note(kind: 'incomplete', message: 'Q2 cut off', qNum: '2'),
        ],
      ));
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    expect(find.text('Q2 cut off'), findsOneWidget);

    // Start re-select then commit a segment — the canvas controller clears the
    // matching note, and the panel should rebuild into the advisory state.
    controller.startReselectForNote(
      const ReviewNote(kind: 'incomplete', message: 'Q2 cut off', qNum: '2'),
    );
    await controller.commitDrawnSegment(_seg());
    await tester.pump();

    expect(find.text('Q2 cut off'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('review-notes-advisory')),
      findsOneWidget,
    );
  });
}
