import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/review/crop_preview_dialog.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('/api/tools/align-offsets')) {
      final jsonStr = jsonEncode(<String, dynamic>{
        'offsets': <double>[0.0, 0.0],
      });
      final stream = Stream<Uint8List>.value(
        Uint8List.fromList(utf8.encode(jsonStr)),
      );
      return ResponseBody(
        stream,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    }

    // Return dummy 1x1 PNG bytes for preview
    final dummyPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final stream = Stream<Uint8List>.value(Uint8List.fromList(dummyPng));
    return ResponseBody(
      stream,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Widget _host(ReviewController controller, int itemIndex) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return CropPreviewDialog(
            controller: controller,
            itemIndex: itemIndex,
          );
        },
      ),
    ),
  );
}

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '/api/preview/$n.png',
    );

QuestionSegment _seg({int page = 1, double xOffset = 0.0, double yOffset = 0.0}) => QuestionSegment(
      page: page,
      xStartPct: 10,
      xEndPct: 40,
      yStartPct: 10,
      yEndPct: 40,
      xOffsetPct: xOffset,
      yOffsetPct: yOffset,
    );

void main() {
  testWidgets('Auto and Reset buttons exist and correctly update the controller state', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dio = Dio()..httpClientAdapter = _FakeAdapter();
    final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
    final controller = ReviewController(apiClient: apiClient);
    
    // Seed with two segments so it is multiPart and has manual nudges.
    // Initial align override is null (default).
    controller.loadFromAnalyze(AnalyzeResponse(
      jobId: 'job-1',
      totalPages: 1,
      methodUsed: 'text',
      pages: <PageInfo>[_page(1)],
      items: <AnalyzedItem>[
        AnalyzedItem(
          qNum: '1',
          isSolution: false,
          source: 'auto',
          align: null,
          segments: <QuestionSegment>[
            _seg(xOffset: 5.0, yOffset: 10.0),
            _seg(xOffset: -3.0, yOffset: 2.0),
          ],
        ),
      ],
      notes: const <ReviewNote>[],
      needsReview: false,
    ));

    await tester.pumpWidget(_host(controller, 0));
    await tester.pumpAndSettle(); // Allow preview rendering to finish loading

    // Verify dialog opened, manual mode controls are active.
    // Since we seeded offsets (5.0, 10.0), _manualMode is indeed true.
    expect(find.byKey(const ValueKey<String>('crop-preview-manual-bar')), findsOneWidget);

    // Recommended Align button should be visible on the align bar.
    final recAlignFinder = find.byKey(const ValueKey<String>('crop-preview-auto-align-action'));
    expect(recAlignFinder, findsOneWidget);

    // Auto button in the sidebar should also be visible.
    final autoFinder = find.byKey(const ValueKey<String>('crop-preview-manual-auto'));
    expect(autoFinder, findsOneWidget);

    // Reset button should be visible.
    final resetFinder = find.byKey(const ValueKey<String>('crop-preview-manual-reset'));
    expect(resetFinder, findsOneWidget);

    // Tap Recommended Align button. It should set align override to true and clear offsets.
    await tester.tap(recAlignFinder);
    await tester.pumpAndSettle();

    expect(controller.alignFor(0), isTrue);
    expect(controller.offsetsFor(0), [0.0, 0.0]);
    expect(controller.yOffsetsFor(0), [0.0, 0.0]);

    // Tap Reset button. Since _initialAlign was null, it should revert align override to null.
    // Let's set some offsets first to test Reset behavior.
    controller.setSegmentOffset(0, 0, xOffsetPct: 2.0, yOffsetPct: 4.0);
    controller.setItemAlign(0, false);
    await tester.pumpAndSettle();

    expect(controller.alignFor(0), isFalse);
    expect(controller.offsetsFor(0), [2.0, 0.0]);

    // Now tap Reset. It should revert align to null (_initialAlign) and reset offsets to 0.0.
    await tester.tap(resetFinder);
    await tester.pumpAndSettle();

    expect(controller.alignFor(0), isNull);
    expect(controller.offsetsFor(0), [0.0, 0.0]);
    expect(controller.yOffsetsFor(0), [0.0, 0.0]);
  });
}
