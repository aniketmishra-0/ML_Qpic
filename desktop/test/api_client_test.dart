// Unit tests for ApiClient — Task 4.3.
//
// These tests focus on the two pieces of behavior task 4.3 owns directly:
//   1. The typed `ApiException(statusCode, detail)` error transform, which must
//      surface the engine's `{"detail": ...}` body VERBATIM for 4xx/5xx
//      responses (and fall back gracefully for non-HTTP failures and non-JSON
//      error bodies).
//   2. The binary download / preview URL builders, which must join the engine's
//      exact paths + query parameters onto the Base_URL without reshaping.
//
// A capturing fake `HttpClientAdapter` is injected into Dio so no real network
// is used; it records the outgoing RequestOptions and returns a canned
// response. (Exhaustive per-endpoint request-construction assertions are
// task 4.4 / Property 1.)

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/models/crop.dart';

/// A fake adapter that returns a fixed response and records the last request.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    required this.statusCode,
    required this.body,
    this.contentType = 'application/json',
  });

  final int statusCode;
  final String body;
  final String contentType;

  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    // Drain any request stream so multipart bodies finalize cleanly.
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _clientReturning({
  required int statusCode,
  required String body,
  String contentType = 'application/json',
}) {
  final dio = Dio();
  dio.httpClientAdapter = _FakeAdapter(
    statusCode: statusCode,
    body: body,
    contentType: contentType,
  );
  // Don't let Dio throw its own error for non-2xx — the adapter still returns a
  // ResponseBody; ApiClient's transform is what we're testing.
  return ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
}

void main() {
  group('ApiException error transform', () {
    test('surfaces the engine {"detail": ...} body verbatim on 400', () async {
      const detail =
          'Question pages are required when the PDF has questions, e.g. '
          "'1-5' or '1 to 5, 8'.";
      final client = _clientReturning(
        statusCode: 400,
        body: jsonEncode(<String, dynamic>{'detail': detail}),
      );

      expect(
        () => client.health(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.detail, 'detail', detail),
        ),
      );
    });

    test('surfaces detail on 422 (no questions detected)', () async {
      const detail = 'No questions detected in this PDF';
      final client = _clientReturning(
        statusCode: 422,
        body: jsonEncode(<String, dynamic>{'detail': detail}),
      );

      expect(
        () => client.snap(
          const SnapRequest(
            jobId: 'job',
            page: 1,
            xStartPct: 0,
            xEndPct: 10,
            yStartPct: 0,
            yEndPct: 10,
          ),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 422)
              .having((e) => e.detail, 'detail', detail),
        ),
      );
    });

    test('surfaces detail on 500 (catch-all handler body)', () async {
      const detail = 'something went wrong';
      final client = _clientReturning(
        statusCode: 500,
        body: jsonEncode(<String, dynamic>{'detail': detail}),
      );

      expect(
        () => client.health(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.detail, 'detail', detail),
        ),
      );
    });

    test('does not throw for a successful 2xx response', () async {
      final client = _clientReturning(
        statusCode: 200,
        body: jsonEncode(<String, dynamic>{
          'status': 'ok',
          'tesseract_available': true,
          'ai_available': false,
          'version': '2.0.0',
        }),
      );

      final health = await client.health();
      expect(health.status, 'ok');
      expect(health.tesseractAvailable, isTrue);
    });
  });

  group('download / preview URL builders', () {
    final client = ApiClient(Uri.parse('http://127.0.0.1:54321'));

    test('cropDownloadUri carries kind + prefixes verbatim', () {
      final uri = client.cropDownloadUri(
        'abc',
        kind: 'questions',
        questionPrefix: 'Q',
        solutionPrefix: 'S',
      );
      expect(uri.path, '/api/crop/download/abc');
      expect(uri.queryParameters['kind'], 'questions');
      expect(uri.queryParameters['question_prefix'], 'Q');
      expect(uri.queryParameters['solution_prefix'], 'S');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, 54321);
    });

    test('analyzePagePreviewUri builds the page preview path', () {
      final uri = client.analyzePagePreviewUri('job1', 3);
      expect(uri.toString(), 'http://127.0.0.1:54321/api/analyze/job1/page/3');
    });

    test('rename/compress/preflight/edit download URIs', () {
      expect(
        client.renameSessionDownloadUri('s1').toString(),
        'http://127.0.0.1:54321/api/rename/session/s1/download',
      );
      expect(
        client.compressDownloadUri('c1').toString(),
        'http://127.0.0.1:54321/api/tools/compress/download/c1',
      );
      expect(
        client.preflightDownloadUri('p1').toString(),
        'http://127.0.0.1:54321/api/tools/preflight/download/p1',
      );
      expect(
        client.editPagePreviewUri('e1', 2).toString(),
        'http://127.0.0.1:54321/api/tools/edit/e1/page/2',
      );
      expect(
        client.editDownloadUri('e1').toString(),
        'http://127.0.0.1:54321/api/tools/edit/download/e1',
      );
    });

    test('resolveUri joins an engine-relative download_url with its query', () {
      final uri = client.resolveUri('/api/crop/download/job?kind=solutions');
      expect(uri.path, '/api/crop/download/job');
      expect(uri.queryParameters['kind'], 'solutions');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, 54321);
    });

    test('resolveUri returns an already-absolute URL unchanged', () {
      final uri = client.resolveUri('http://example.test/x');
      expect(uri.toString(), 'http://example.test/x');
    });
  });
}
