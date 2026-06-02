import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/review/review_canvas.dart';
import 'package:qpic_desktop/features/review/review_canvas_controller.dart';
import 'package:qpic_desktop/models/crop.dart';

// Widget-level verification of the ReviewCanvas input layer: a real
// GestureDetector + MouseRegion drives the controller through pointer events
// (Req 8.3, 8.4, 8.7, 8.8, 8.12). Network image loading is avoided by leaving
// previewUrl resolution to the default (the painter simply draws no image).

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '', // empty → no network fetch in the test
    );

AnalyzedItem _item({
  String qNum = '1',
  List<QuestionSegment>? segments,
}) =>
    AnalyzedItem(
      qNum: qNum,
      source: 'auto',
      segments: segments ??
          const <QuestionSegment>[
            QuestionSegment(
              page: 1,
              xStartPct: 10,
              xEndPct: 50,
              yStartPct: 10,
              yEndPct: 50,
            ),
          ],
    );

Future<void> _pump(
  WidgetTester tester,
  ReviewCanvasController controller, {
  Size size = const Size(400, 500),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: QpicTheme.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: ReviewCanvas(controller: controller),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('drag on empty area draws a new box (Req 8.4)', (tester) async {
    final controller = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
    await _pump(tester, controller);

    final Finder canvas = find.byType(ReviewCanvas);
    final Rect box = tester.getRect(canvas);
    // Drag from ~20%,20% to ~70%,70% of the 400x500 viewport — well above the
    // 1.5% min-box threshold.
    final Offset start = box.topLeft + const Offset(80, 100);
    final Offset end = box.topLeft + const Offset(280, 350);
    await tester.dragFrom(start, end - start);
    await tester.pumpAndSettle();

    expect(controller.items.length, 1);
    expect(controller.items.single.source, 'manual');
  });

  testWidgets('a tiny drag creates no box (Req 8.5)', (tester) async {
    final controller = ReviewCanvasController(pages: <PageInfo>[_page(1)]);
    await _pump(tester, controller);

    final Rect box = tester.getRect(find.byType(ReviewCanvas));
    final Offset start = box.topLeft + const Offset(80, 100);
    // ~1px drag → well under 1.5% of width/height → discarded.
    await tester.dragFrom(start, const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(controller.items, isEmpty);
  });

  testWidgets('hover over a box sets the hovered label (Req 8.3)',
      (tester) async {
    final controller = ReviewCanvasController(
      pages: <PageInfo>[_page(1)],
      items: <AnalyzedItem>[_item(qNum: '7')],
    );
    await _pump(tester, controller);

    final Rect box = tester.getRect(find.byType(ReviewCanvas));
    // The item spans 10%..50% on a 400px-wide fit-width page → 40..200 px.
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(box.topLeft + const Offset(80, 100)); // ~20%,20%
    await tester.pump();
    expect(controller.hoveredLabel, '7');

    // Move far outside the box.
    await gesture.moveTo(box.topLeft + const Offset(380, 480));
    await tester.pump();
    expect(controller.hoveredItemIndex, -1);
  });

  testWidgets('page navigation shows only that page (Req 8.12)',
      (tester) async {
    final controller = ReviewCanvasController(
      pages: <PageInfo>[_page(1), _page(2), _page(3)],
    );
    await _pump(tester, controller);

    expect(controller.currentPageNumber, 1);
    controller.nextPage();
    await tester.pump();
    expect(controller.currentPageNumber, 2);

    // Clamp at the last page.
    controller.gotoPageIndex(99);
    await tester.pump();
    expect(controller.currentPageNumber, 3);
    expect(controller.isLastPage, isTrue);
  });

  testWidgets('per-box delete affordance removes the box in re-select (Req 8.7)',
      (tester) async {
    final controller = ReviewCanvasController(
      pages: <PageInfo>[_page(1)],
      items: <AnalyzedItem>[
        _item(qNum: '3', segments: const <QuestionSegment>[
          QuestionSegment(
            page: 1,
            xStartPct: 20,
            xEndPct: 60,
            yStartPct: 20,
            yEndPct: 60,
          ),
        ]),
      ],
    );
    await _pump(tester, controller);
    controller.startEditing(0);
    await tester.pump();

    final Rect canvasRect = tester.getRect(find.byType(ReviewCanvas));
    final double pageW = canvasRect.width;
    final double rightX = canvasRect.left + 0.60 * pageW;
    final double topY = canvasRect.top + 0.20 * (pageW * 800 / 600);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(Offset(rightX, topY - 11));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.items.single.segments, isEmpty);
  });
}
