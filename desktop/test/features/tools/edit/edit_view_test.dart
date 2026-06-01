// Widget tests for EditView — open + clickable span overlays (Req 15.2, 15.3, 15.8).
//
// These confirm the view renders the open prompt, surfaces an engine error,
// renders one clickable box per span over each page's server-rendered preview,
// selects a span on tap, and shows the OCR guidance when the PDF has no text.
// A fake Dio adapter feeds the controller canned `edit/open` responses so no
// real network is used.

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/tools/edit/edit_controller.dart';
import 'package:qpic_desktop/features/tools/edit/edit_view.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
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

EditController _controller({required int statusCode, required String body}) {
  final dio = Dio()
    ..httpClientAdapter = _FakeAdapter(statusCode: statusCode, body: body);
  return EditController(api: ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio));
}

Widget _host(EditController controller, {VoidCallback? onPickFile}) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(
      body: EditView(controller: controller, onPickFile: onPickFile),
    ),
  );
}

const String _openBodyWithText = '''
{
  "job_id": "job-1",
  "has_text": true,
  "pages": [
    {"page": 1, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/job-1/page/1"}
  ],
  "spans": [
    {"id": "p1_b0_l0_s0", "page": 1, "text": "Hello", "bbox": [10.0, 20.0, 100.0, 40.0], "font": "Helvetica", "size": 12.0, "color": 1118481, "bold": false, "italic": false},
    {"id": "p1_b0_l1_s0", "page": 1, "text": "World", "bbox": [10.0, 60.0, 120.0, 80.0], "font": "Helvetica", "size": 12.0, "color": 1118481, "bold": false, "italic": false}
  ]
}
''';

const String _openBodyNoText = '''
{
  "job_id": "job-2",
  "has_text": false,
  "pages": [
    {"page": 1, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/job-2/page/1"}
  ],
  "spans": []
}
''';

void main() {
  testWidgets('idle state shows the open prompt', (tester) async {
    final controller = _controller(statusCode: 200, body: '{}');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller, onPickFile: () {}));

    expect(find.byKey(const ValueKey('edit-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-pick-file')), findsOneWidget);
  });

  testWidgets('renders one clickable box per span over the page', (tester) async {
    final controller = _controller(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    await tester.runAsync(
      () => controller.open(fileBytes: const <int>[1], filename: 'a.pdf'),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('edit-page-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-span-p1_b0_l0_s0')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-span-p1_b0_l1_s0')), findsOneWidget);
    // No OCR guidance when the PDF has selectable text.
    expect(find.byKey(const ValueKey('edit-no-text-guidance')), findsNothing);
  });

  testWidgets('tapping a span selects it', (tester) async {
    final controller = _controller(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    await tester.runAsync(
      () => controller.open(fileBytes: const <int>[1], filename: 'a.pdf'),
    );
    await tester.pump();

    expect(controller.selectedSpanId, isNull);
    await tester.tap(find.byKey(const ValueKey('edit-span-p1_b0_l0_s0')));
    await tester.pump();
    expect(controller.selectedSpanId, 'p1_b0_l0_s0');
  });

  testWidgets('shows the OCR guidance when the PDF has no selectable text',
      (tester) async {
    final controller = _controller(statusCode: 200, body: _openBodyNoText);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    await tester.runAsync(
      () => controller.open(fileBytes: const <int>[1], filename: 'scan.pdf'),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('edit-no-text-guidance')), findsOneWidget);
    // A scanned PDF has no spans to overlay.
    expect(find.byKey(const ValueKey('edit-span-p1_b0_l0_s0')), findsNothing);
  });

  testWidgets('open error surfaces the engine detail', (tester) async {
    final controller = _controller(
      statusCode: 400,
      body: '{"detail": "That file is not a valid PDF."}',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller, onPickFile: () {}));
    await tester.runAsync(
      () => controller.open(fileBytes: const <int>[1], filename: 'x.pdf'),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('edit-error')), findsOneWidget);
    expect(find.text('That file is not a valid PDF.'), findsOneWidget);
  });
}
