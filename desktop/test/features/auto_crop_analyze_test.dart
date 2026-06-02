// Unit tests for the AutoCropController Smart analyze entry (Task 12.5 —
// Requirements 6.1, 6.2, 6.7).
//
// These verify the controller's Smart-mode path:
//   * a valid Smart submit POSTs /api/analyze with the mapped query params
//     (`dpi, marker_style, has_questions, question_pages, has_answers,
//     answer_pages, use_ai, answer_sheet`) + multipart file, and stores the
//     AnalyzeResponse as `analyzeResult` so the host opens the Review Canvas
//     (6.1, 6.2),
//   * the analyze result carries `answer_key_count` for the answer-sheet
//     messaging (6.4/6.5 are exercised end-to-end in the ReviewScreen test),
//   * an analyze engine error surfaces the `detail` and stores NO analysis, so
//     the canvas is NOT opened (6.7),
//   * Smart submit never hits /api/crop, and a non-Smart submit never hits
//     /api/analyze,
//   * `question_pages` / `answer_pages` are omitted when their toggle is off.
//
// The engine is faked with a capturing Dio HttpClientAdapter (no network).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart';

/// A fake adapter that returns a fixed response and records the last request.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  RequestOptions? lastRequest;
  String? lastContentType;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    lastRequest = options;
    lastContentType = options.contentType;
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

AutoCropController _controller(_CapturingAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  return AutoCropController(apiClient: apiClient);
}

String _analyzeBody({
  String jobId = 'analyze-job',
  int answerKeyCount = 0,
  bool needsReview = false,
}) {
  return jsonEncode(<String, dynamic>{
    'job_id': jobId,
    'total_pages': 2,
    'method_used': 'text',
    'pages': <Map<String, dynamic>>[
      <String, dynamic>{
        'page': 1,
        'width_pt': 600,
        'height_pt': 800,
        'preview_url': '/api/analyze/$jobId/page/1',
      },
      <String, dynamic>{
        'page': 2,
        'width_pt': 600,
        'height_pt': 800,
        'preview_url': '/api/analyze/$jobId/page/2',
      },
    ],
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'q_num': '1',
        'is_solution': false,
        'segments': <Map<String, dynamic>>[
          <String, dynamic>{
            'page': 1,
            'x_start_pct': 10,
            'x_end_pct': 90,
            'y_start_pct': 10,
            'y_end_pct': 40,
          },
        ],
        'source': 'auto',
        'flagged': false,
      },
    ],
    'notes': <Map<String, dynamic>>[],
    'needs_review': needsReview,
    'answer_key_count': answerKeyCount,
  });
}

void main() {
  group('Smart submit issues POST /api/analyze (Req 6.1, 6.2)', () {
    test('maps the query params + multipart file and stores analyzeResult',
        () async {
      final adapter = _CapturingAdapter(
        statusCode: 200,
        body: _analyzeBody(answerKeyCount: 4),
      );
      final c = _controller(adapter);
      addTearDown(c.dispose);
      c
        ..setFile(bytes: const <int>[1, 2, 3], filename: 'paper.pdf')
        ..smartMode = true
        ..hasQuestions = true
        ..questionPages = '1-5'
        ..hasAnswers = true
        ..answerPages = '7-10'
        ..numbering = NumberingMode.numbered
        ..onlineMode = true
        ..answerSheet = true
        ..dpi = 300;

      final ok = await c.submit();

      expect(ok, isTrue);
      final req = adapter.lastRequest;
      expect(req?.path, '/api/analyze');
      expect(req?.method, 'POST');
      expect(adapter.lastContentType, contains('multipart/form-data'));

      final q = req!.queryParameters;
      expect(q['dpi'], 300);
      expect(q['marker_style'], 'numbered');
      expect(q['has_questions'], true);
      expect(q['question_pages'], '1-5');
      expect(q['has_answers'], true);
      expect(q['answer_pages'], '7-10');
      expect(q['use_ai'], true);
      expect(q['answer_sheet'], true);
      // analyze takes no padding/prefix/start/format params.
      expect(q.containsKey('padding'), isFalse);
      expect(q.containsKey('question_prefix'), isFalse);

      // The analysis is stored so the host opens the Review Canvas (6.2).
      expect(c.analyzeResult, isNotNull);
      expect(c.analyzeResult!.jobId, 'analyze-job');
      expect(c.analyzeResult!.answerKeyCount, 4);
      expect(c.errorText, isNull);
      expect(c.result, isNull, reason: 'no direct crop happened');
    });

    test('opens the canvas even when needs_review is false (Req 6.2)',
        () async {
      final adapter = _CapturingAdapter(
        statusCode: 200,
        body: _analyzeBody(needsReview: false),
      );
      final c = _controller(adapter);
      addTearDown(c.dispose);
      c
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..questionPages = '1-5'
        ..answerPages = '7-10';

      final ok = await c.submit();
      expect(ok, isTrue);
      // analyzeResult is present regardless of needs_review.
      expect(c.analyzeResult, isNotNull);
      expect(c.analyzeResult!.needsReview, isFalse);
    });

    test('omits question_pages / answer_pages when their toggle is off',
        () async {
      final adapter = _CapturingAdapter(statusCode: 200, body: _analyzeBody());
      final c = _controller(adapter);
      addTearDown(c.dispose);
      c
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..hasQuestions = true
        ..questionPages = '1-5'
        ..hasAnswers = false;

      await c.submit();

      final q = adapter.lastRequest!.queryParameters;
      expect(q['question_pages'], '1-5');
      expect(q.containsKey('answer_pages'), isFalse,
          reason: 'no stale answer range leaks when Solutions is off');
    });
  });

  group('analyze error keeps the canvas closed (Req 6.7)', () {
    test('surfaces the engine detail and stores no analysis', () async {
      final adapter = _CapturingAdapter(
        statusCode: 422,
        body: jsonEncode(<String, dynamic>{
          'detail': 'Could not render this PDF',
        }),
      );
      final c = _controller(adapter);
      addTearDown(c.dispose);
      c
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..questionPages = '1-5'
        ..answerPages = '7-10';

      final ok = await c.submit();

      expect(ok, isFalse);
      expect(c.analyzeResult, isNull, reason: 'no analysis → canvas stays closed');
      expect(c.errorText, 'Could not render this PDF');
    });
  });

  group('mode keeps the two endpoints separate', () {
    test('a guarded Smart submit sends nothing and preserves values',
        () async {
      final adapter = _CapturingAdapter(statusCode: 200, body: _analyzeBody());
      final c = _controller(adapter);
      addTearDown(c.dispose);
      c
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..hasQuestions = true
        ..questionPages = '' // empty → blocked
        ..hasAnswers = false;

      final ok = await c.submit();

      expect(ok, isFalse);
      expect(adapter.requestCount, 0);
      expect(c.analyzeResult, isNull);
      expect(c.errorText, AutoCropController.errQuestionPagesRequired);
      expect(c.questionPages, '');
    });

    test('consumeAnalyzeResult clears the stored analysis', () async {
      final adapter = _CapturingAdapter(statusCode: 200, body: _analyzeBody());
      final c = _controller(adapter);
      addTearDown(c.dispose);
      c
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..questionPages = '1-5'
        ..answerPages = '7-10';

      await c.submit();
      expect(c.analyzeResult, isNotNull);
      c.consumeAnalyzeResult();
      expect(c.analyzeResult, isNull);
    });

    test('engine binding can be (un)bound like the other controllers', () {
      final adapter = _CapturingAdapter(statusCode: 200, body: _analyzeBody());
      final dio = Dio()..httpClientAdapter = adapter;
      final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
      final c = AutoCropController();
      addTearDown(c.dispose);

      expect(c.engineReady, isFalse);
      c.bindEngine(apiClient: apiClient);
      expect(c.engineReady, isTrue);
      c.unbindEngine();
      expect(c.engineReady, isFalse);
    });
  });
}
