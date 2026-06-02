// Widget tests for the Manual Crop view (Task 13.1 — Requirements 7.2, 7.6).
//
// These verify the view's two surfaces:
//   * the open form shows the file picker + the tool's independent output
//     config, and surfaces the prepare-manual error banner (7.6),
//   * once the controller reports canvasOpen, the Review Canvas surface appears
//     with the page indicator (7.2).
//
// The engine is faked with a capturing Dio adapter; page previews use an empty
// preview_url so no network fetch occurs in the test.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/manual_crop/manual_crop_controller.dart';
import 'package:qpic_desktop/features/manual_crop/manual_crop_view.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';

class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ManualCropController _controller({required int statusCode, required String body}) {
  final dio = Dio()..httpClientAdapter = _FixedAdapter(statusCode: statusCode, body: body);
  final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  return ManualCropController(apiClient: apiClient);
}

String _prepareBody({int pages = 2}) => jsonEncode(<String, dynamic>{
      'job_id': 'manual-job',
      'total_pages': pages,
      'method_used': 'text',
      'pages': <Map<String, dynamic>>[
        for (int i = 1; i <= pages; i++)
          <String, dynamic>{
            'page': i,
            'width_pt': 600.0,
            'height_pt': 800.0,
            'preview_url': '', // empty → no network fetch in the test
          },
      ],
      'items': <dynamic>[],
      'notes': <dynamic>[],
      'needs_review': false,
      'answer_key_count': 0,
    });

Future<void> _pump(WidgetTester tester, ManualCropController controller) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: QpicTheme.dark,
      home: Scaffold(
        body: ManualCropView(controller: controller),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('open form shows the picker + independent output config',
      (tester) async {
    final c = _controller(statusCode: 200, body: _prepareBody());
    addTearDown(c.dispose);
    await _pump(tester, c);

    expect(find.byKey(const ValueKey<String>('manual-crop-title')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manual-crop-pick-file')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manual-crop-question-prefix')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manual-crop-start-number')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manual-crop-image-format')),
      findsOneWidget,
    );
  });

  testWidgets('canvas surface appears once prepare-manual succeeds (Req 7.2)',
      (tester) async {
    final c = _controller(statusCode: 200, body: _prepareBody(pages: 2));
    addTearDown(c.dispose);
    await _pump(tester, c);

    c.setFile(bytes: const <int>[1], filename: 'paper.pdf');
    await tester.runAsync(() => c.open());
    await tester.pump();

    // Reuses the shared ReviewScreen host (same as Smart Auto Crop).
    expect(find.byKey(const ValueKey<String>('manual-crop-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('review-canvas')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('review-page-indicator')),
      findsOneWidget,
    );
    expect(find.text('Page 1 / 2  (p1)'), findsOneWidget);

    // Back returns to the open form.
    await tester.tap(find.byKey(const ValueKey<String>('review-back')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('manual-crop-canvas')), findsNothing);
    expect(find.byKey(const ValueKey<String>('manual-crop-pick-file')), findsOneWidget);
  });

  testWidgets('prepare-manual error shows a banner, no canvas (Req 7.6)',
      (tester) async {
    final c = _controller(
      statusCode: 400,
      body: jsonEncode(<String, dynamic>{'detail': 'Please upload a PDF file.'}),
    );
    addTearDown(c.dispose);
    await _pump(tester, c);

    c.setFile(bytes: const <int>[0], filename: 'photo.png');
    await tester.runAsync(() => c.open());
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manual-crop-error')), findsOneWidget);
    expect(find.text('Please upload a PDF file.'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manual-crop-canvas')), findsNothing);
  });

  testWidgets('Finalize with no items prompts to draw a crop (Req 7.5)',
      (tester) async {
    final c = _controller(statusCode: 200, body: _prepareBody(pages: 2));
    addTearDown(c.dispose);
    await _pump(tester, c);

    c.setFile(bytes: const <int>[1], filename: 'paper.pdf');
    await tester.runAsync(() => c.open());
    await tester.pump();

    // The Finalize control is present (engine bound). Tapping it with an empty
    // item list blocks and surfaces the prompt instead of opening a download.
    final finalize = find.byKey(const ValueKey<String>('review-finalize'));
    expect(finalize, findsOneWidget);
    await tester.tap(finalize);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('review-finalize-error')),
      findsOneWidget,
    );
    expect(find.text(ReviewController.errNoItems), findsOneWidget);
    // No download bar — nothing was finalized.
    expect(
      find.byKey(const ValueKey<String>('review-finalize-download-bar')),
      findsNothing,
    );
  });
}
