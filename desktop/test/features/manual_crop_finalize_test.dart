// Unit tests for the Manual Crop finalize flow + guards
// (Task 13.2 — Requirements 7.4, 7.5, 7.7).
//
// These verify the ManualCropController's finalize, which delegates to the
// shared ReviewController.finalize with the Manual Crop tool's OWN output
// config:
//   * finalize() POSTs /api/finalize with the job id, the hand-drawn items, and
//     the tool's independent question_prefix/solution_prefix/start_number/
//     image_format/jpg_quality values (7.4),
//   * an EMPTY item list blocks finalize, sends no request, and prompts the user
//     to draw at least one crop (7.5),
//   * a finalize error retains the hand-drawn items so the user can retry (7.7).
//
// The engine is faked with a capturing Dio HttpClientAdapter (no network). Boxes
// are added to the shared review canvas exactly as a hand-drawn crop would be
// (commitSegmentSync), so the payload reflects real manual items.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart'
    show CropImageFormat;
import 'package:qpic_desktop/features/manual_crop/manual_crop_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

/// A fake adapter that returns a fixed response and records the last request
/// (path, method, and decoded JSON body for the finalize POST).
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  RequestOptions? lastRequest;
  Map<String, dynamic>? lastJsonBody;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    lastRequest = options;
    final dynamic data = options.data;
    if (data is Map) {
      lastJsonBody = Map<String, dynamic>.from(data);
    } else if (data is String && data.isNotEmpty) {
      try {
        lastJsonBody = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        lastJsonBody = null;
      }
    }
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

/// Builds a controller whose ApiClient returns [body] with [statusCode].
ManualCropController _controllerFor({
  required int statusCode,
  required String body,
  void Function(_CapturingAdapter adapter)? capture,
}) {
  final adapter = _CapturingAdapter(statusCode: statusCode, body: body);
  capture?.call(adapter);
  final dio = Dio()..httpClientAdapter = adapter;
  final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  return ManualCropController(apiClient: apiClient);
}

/// A minimal manual review session (two pages, empty items) — the shape
/// `POST /api/prepare-manual` returns. Loaded directly via [loadFromManual]
/// where we want to control the canvas without an open() round-trip.
AnalyzeResponse _manualSession({int pages = 2}) {
  return AnalyzeResponse.fromJson(<String, dynamic>{
    'job_id': 'manual-job-1',
    'total_pages': pages,
    'method_used': 'text',
    'pages': <Map<String, dynamic>>[
      for (int i = 1; i <= pages; i++)
        <String, dynamic>{
          'page': i,
          'width_pt': 600.0,
          'height_pt': 800.0,
          'preview_url': '/api/analyze/manual-job-1/page/$i',
        },
    ],
    'items': <dynamic>[],
    'notes': <dynamic>[],
    'needs_review': false,
    'answer_key_count': 0,
  });
}

/// A successful finalize CropResponse body.
String _cropBody({String jobId = 'manual-job-1', int questionsCount = 1}) {
  return jsonEncode(<String, dynamic>{
    'job_id': jobId,
    'total_questions': questionsCount,
    'stitched_questions': 0,
    'method_used': 'text',
    'download_url': '/api/crop/download/$jobId',
    'questions_download_url': null,
    'solutions_download_url': null,
    'questions_count': questionsCount,
    'solutions_count': 0,
    'answer_sheet_included': false,
    'answers_count': 0,
  });
}

/// Draws one hand-drawn box onto the shared review canvas, exactly as a user
/// crop would (large enough to clear the 1.5% min-box guard).
void _drawBox(
  ManualCropController c, {
  bool isSolution = false,
  double x0 = 10,
  double x1 = 50,
  double y0 = 10,
  double y1 = 50,
}) {
  c.review.setDrawAsSolution(isSolution);
  c.review.canvas.commitSegmentSync(
    QuestionSegment(
      page: c.review.currentPageNumber,
      xStartPct: x0,
      xEndPct: x1,
      yStartPct: y0,
      yEndPct: y1,
    ),
  );
}

void main() {
  group('manual finalize POSTs /api/finalize with the tool config (Req 7.4)',
      () {
    test('sends the job id, hand-drawn items, and the tool OWN output config',
        () async {
      late _CapturingAdapter adapter;
      final c = _controllerFor(
        statusCode: 200,
        body: _cropBody(),
        capture: (a) => adapter = a,
      );
      addTearDown(c.dispose);

      // The Manual Crop tool's own independent output config (Req 7.3/7.4).
      c
        ..questionPrefix = 'MQ'
        ..solutionPrefix = 'MS'
        ..startNumber = 9
        ..imageFormat = CropImageFormat.jpg
        ..jpgQuality = 70
        ..dpi = 240;

      // Load a manual session (empty items), then hand-draw two crops.
      c.review.loadFromManual(_manualSession());
      _drawBox(c); // a question
      _drawBox(c, isSolution: true, x0: 12, x1: 60, y0: 60, y1: 90);

      final ok = await c.finalize();

      expect(ok, isTrue);
      expect(adapter.lastRequest?.path, '/api/finalize');
      expect(adapter.lastRequest?.method, 'POST');

      final body = adapter.lastJsonBody!;
      expect(body['job_id'], 'manual-job-1');
      // The tool's OWN output config rode on the request (Req 7.4).
      expect(body['question_prefix'], 'MQ');
      expect(body['solution_prefix'], 'MS');
      expect(body['start_number'], 9);
      expect(body['image_format'], 'jpg');
      expect(body['jpg_quality'], 70);
      expect(body['dpi'], 240);
      // Manual crop carries no detected answer key → no answer sheet.
      expect(body['answer_sheet'], false);

      // Both hand-drawn items are in the payload, each with its type + region.
      final items = body['items'] as List<dynamic>;
      expect(items.length, 2);
      final q = items[0] as Map<String, dynamic>;
      final s = items[1] as Map<String, dynamic>;
      expect(q['is_solution'], false);
      expect(q['source'], 'manual');
      expect(s['is_solution'], true);
      expect(
        (q['segments'] as List<dynamic>).single as Map<String, dynamic>,
        containsPair('x_start_pct', 10),
      );
    });

    test('defaults are the Manual Crop tool own values (not an Auto source)',
        () async {
      late _CapturingAdapter adapter;
      final c = _controllerFor(
        statusCode: 200,
        body: _cropBody(),
        capture: (a) => adapter = a,
      );
      addTearDown(c.dispose);

      c.review.loadFromManual(_manualSession());
      _drawBox(c);

      await c.finalize();

      final body = adapter.lastJsonBody!;
      expect(body['question_prefix'], 'Q');
      expect(body['solution_prefix'], 'S');
      expect(body['image_format'], 'png');
    });

    test('full open() → draw → finalize round-trip issues both requests',
        () async {
      // A single adapter answers both prepare-manual and finalize, so use a
      // body that satisfies BOTH parsers (AnalyzeResponse + CropResponse) — the
      // two factories read disjoint keys and ignore extras. We assert the
      // finalize is the LAST request and that it succeeded.
      final mergedBody = jsonEncode(<String, dynamic>{
        ..._manualSession().toJson(),
        'total_questions': 1,
        'stitched_questions': 0,
        'download_url': '/api/crop/download/manual-job-1',
        'questions_download_url': null,
        'solutions_download_url': null,
        'questions_count': 1,
        'solutions_count': 0,
        'answer_sheet_included': false,
        'answers_count': 0,
      });
      late _CapturingAdapter adapter;
      final c = _controllerFor(
        statusCode: 200,
        body: mergedBody,
        capture: (a) => adapter = a,
      );
      addTearDown(c.dispose);

      c.setFile(bytes: const <int>[1, 2, 3], filename: 'paper.pdf');
      final opened = await c.open();
      expect(opened, isTrue);
      expect(c.canvasOpen, isTrue);
      _drawBox(c);

      final ok = await c.finalize();
      expect(ok, isTrue);
      expect(adapter.lastRequest?.path, '/api/finalize');
      expect(adapter.requestCount, 2); // prepare-manual + finalize
    });
  });

  group('empty item list blocks finalize and prompts (Req 7.5)', () {
    test('no items → blocked, no request sent, prompt surfaced', () async {
      late _CapturingAdapter adapter;
      final c = _controllerFor(
        statusCode: 200,
        body: _cropBody(),
        capture: (a) => adapter = a,
      );
      addTearDown(c.dispose);

      // Manual session opens with an EMPTY item list — nothing drawn yet.
      c.review.loadFromManual(_manualSession());

      final ok = await c.finalize();

      expect(ok, isFalse);
      // No finalize request was sent at all.
      expect(adapter.requestCount, 0);
      expect(c.finalizeError, ReviewController.errNoItems);
    });
  });

  group('finalize error retains the hand-drawn items (Req 7.7)', () {
    test('a 404 surfaces detail and keeps the items for retry', () async {
      final c = _controllerFor(
        statusCode: 404,
        body: jsonEncode(<String, dynamic>{'detail': 'Job ID not found'}),
      );
      addTearDown(c.dispose);

      c.review.loadFromManual(_manualSession());
      _drawBox(c);
      _drawBox(c, isSolution: true, x0: 20, x1: 70, y0: 20, y1: 80);
      expect(c.review.items.length, 2);

      final ok = await c.finalize();

      expect(ok, isFalse);
      expect(c.finalizeError, 'Job ID not found');
      // Items retained so the user can fix and retry (Req 7.7).
      expect(c.review.items.length, 2);
    });
  });

  group('finalize guards against an unbound engine', () {
    test('no engine bound → finalize is a no-op', () async {
      final c = ManualCropController();
      addTearDown(c.dispose);
      c.review.loadFromManual(_manualSession());
      _drawBox(c);

      expect(await c.finalize(), isFalse);
    });
  });
}
