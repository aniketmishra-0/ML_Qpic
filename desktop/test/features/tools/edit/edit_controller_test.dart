// Unit tests for EditController.open (Req 15.1, 15.8).
//
// A capturing fake HttpClientAdapter is injected into Dio so no real network is
// used; it returns a canned `edit/open` response. These verify the open flow's
// status transitions, that the staged response is exposed (pages/spans/hasText),
// that spans are filtered per page, and that an engine error surfaces `detail`.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/tools/edit/edit_controller.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
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

EditController _controllerReturning({
  required int statusCode,
  required String body,
}) {
  final dio = Dio();
  dio.httpClientAdapter =
      _FakeAdapter(statusCode: statusCode, body: body);
  final api = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  return EditController(api: api);
}

const String _openBodyWithText = '''
{
  "job_id": "job-1",
  "has_text": true,
  "pages": [
    {"page": 1, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/job-1/page/1"},
    {"page": 2, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/job-1/page/2"}
  ],
  "spans": [
    {"id": "p1_b0_l0_s0", "page": 1, "text": "Hello", "bbox": [10.0, 20.0, 100.0, 40.0], "font": "Helvetica", "size": 12.0, "color": 1118481, "bold": false, "italic": false},
    {"id": "p2_b0_l0_s0", "page": 2, "text": "World", "bbox": [10.0, 20.0, 100.0, 40.0], "font": "Helvetica", "size": 12.0, "color": 1118481, "bold": false, "italic": false}
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
  test('starts idle with no document', () {
    final controller = _controllerReturning(statusCode: 200, body: '{}');
    addTearDown(controller.dispose);
    expect(controller.status, EditStatus.idle);
    expect(controller.hasDocument, isFalse);
    expect(controller.hasText, isFalse);
    expect(controller.pages, isEmpty);
  });

  test('open success stores response and transitions to ready', () async {
    final controller =
        _controllerReturning(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);

    final ok = await controller.open(fileBytes: const <int>[1, 2, 3], filename: 'a.pdf');

    expect(ok, isTrue);
    expect(controller.status, EditStatus.ready);
    expect(controller.hasDocument, isTrue);
    expect(controller.hasText, isTrue);
    expect(controller.fileName, 'a.pdf');
    expect(controller.pages, hasLength(2));
    expect(controller.spans, hasLength(2));
    expect(controller.response?.jobId, 'job-1');
  });

  test('spansForPage filters by the engine page number', () async {
    final controller =
        _controllerReturning(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);
    await controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

    expect(controller.spansForPage(1).map((s) => s.id), <String>['p1_b0_l0_s0']);
    expect(controller.spansForPage(2).map((s) => s.id), <String>['p2_b0_l0_s0']);
    expect(controller.spansForPage(3), isEmpty);
  });

  test('previewUri joins the engine preview_url onto the base url', () async {
    final controller =
        _controllerReturning(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);
    await controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

    final uri = controller.previewUri(controller.pages.first);
    expect(uri.toString(), 'http://127.0.0.1:54321/api/tools/edit/job-1/page/1');
  });

  test('open with has_text false exposes the OCR-guidance condition', () async {
    final controller =
        _controllerReturning(statusCode: 200, body: _openBodyNoText);
    addTearDown(controller.dispose);

    await controller.open(fileBytes: const <int>[1], filename: 'scan.pdf');

    expect(controller.status, EditStatus.ready);
    expect(controller.hasText, isFalse);
    expect(controller.spans, isEmpty);
    expect(controller.pages, hasLength(1));
  });

  test('open failure surfaces the engine detail verbatim', () async {
    const detail = 'That file is not a valid PDF.';
    final controller = _controllerReturning(
      statusCode: 400,
      body: jsonEncode(<String, dynamic>{'detail': detail}),
    );
    addTearDown(controller.dispose);

    final ok = await controller.open(fileBytes: const <int>[1], filename: 'x.pdf');

    expect(ok, isFalse);
    expect(controller.status, EditStatus.error);
    expect(controller.errorDetail, detail);
    expect(controller.hasDocument, isFalse);
  });

  test('selectSpan updates the selected id and notifies', () async {
    final controller =
        _controllerReturning(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);
    await controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

    int notifications = 0;
    controller.addListener(() => notifications++);

    controller.selectSpan('p1_b0_l0_s0');
    expect(controller.selectedSpanId, 'p1_b0_l0_s0');
    expect(notifications, 1);

    // Selecting the same span again does not re-notify.
    controller.selectSpan('p1_b0_l0_s0');
    expect(notifications, 1);

    controller.selectSpan(null);
    expect(controller.selectedSpanId, isNull);
    expect(notifications, 2);
  });

  test('reset clears the staged document', () async {
    final controller =
        _controllerReturning(statusCode: 200, body: _openBodyWithText);
    addTearDown(controller.dispose);
    await controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

    controller.reset();
    expect(controller.status, EditStatus.idle);
    expect(controller.hasDocument, isFalse);
    expect(controller.fileName, isNull);
  });
}
