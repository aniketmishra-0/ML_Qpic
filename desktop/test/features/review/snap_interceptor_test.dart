// Unit tests for snap-to-content (Task 12.2, Req 9.1–9.4).
//
// These verify the box-end snap behavior wired through `buildSnapInterceptor`
// and `ReviewController.attachSnap`:
//   * Req 9.1 — `POST /api/snap` carries job_id, page, and the box's four
//                page-percentage coordinates.
//   * Req 9.2 — a successful response replaces the box with the tightened rect.
//   * Req 9.3 — an unchanged (echoed-back) response keeps the drawn box.
//   * Req 9.4 — an error response keeps the drawn box unchanged.
//
// The engine is faked with a capturing Dio HttpClientAdapter (no network); it
// records the outgoing request body and returns a canned snap response (or an
// error status). Property 9 ("snap never degrades" across all inputs) is the
// separate task 12.3.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/features/review/snap_interceptor.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

/// A fake adapter that returns a fixed response and records the last request
/// body, draining any request stream.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  RequestOptions? lastRequest;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    requestCount++;
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

({ApiClient client, _CapturingAdapter adapter}) _client({
  required int statusCode,
  required String body,
}) {
  final adapter = _CapturingAdapter(statusCode: statusCode, body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    client: ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio),
    adapter: adapter,
  );
}

String _snapBody({
  double x0 = 0,
  double x1 = 0,
  double y0 = 0,
  double y1 = 0,
}) =>
    jsonEncode(<String, dynamic>{
      'x_start_pct': x0,
      'x_end_pct': x1,
      'y_start_pct': y0,
      'y_end_pct': y1,
    });

QuestionSegment _drawn({
  int page = 2,
  double x0 = 10,
  double x1 = 60,
  double y0 = 20,
  double y1 = 70,
}) =>
    QuestionSegment(
      page: page,
      xStartPct: x0,
      xEndPct: x1,
      yStartPct: y0,
      yEndPct: y1,
    );

void main() {
  group('buildSnapInterceptor (Req 9)', () {
    test('Req 9.1 — sends job_id, page, and the box coordinates', () async {
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 12, x1: 55, y0: 25, y1: 65),
      );
      final intercept = buildSnapInterceptor(
        apiClient: h.client,
        jobId: () => 'job-xyz',
        enabled: () => true,
      );

      await intercept(_drawn(page: 3, x0: 11, x1: 61, y0: 22, y1: 72));

      final req = h.adapter.lastRequest!;
      expect(req.method, 'POST');
      expect(req.path, '/api/snap');
      final Map<String, dynamic> sent = req.data as Map<String, dynamic>;
      expect(sent['job_id'], 'job-xyz');
      expect(sent['page'], 3);
      expect(sent['x_start_pct'], 11);
      expect(sent['x_end_pct'], 61);
      expect(sent['y_start_pct'], 22);
      expect(sent['y_end_pct'], 72);
    });

    test('Req 9.2 — replaces the box with the returned tightened rect',
        () async {
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 12, x1: 55, y0: 25, y1: 65),
      );
      final intercept = buildSnapInterceptor(
        apiClient: h.client,
        jobId: () => 'job-1',
        enabled: () => true,
      );

      final QuestionSegment out = await intercept(_drawn(page: 4));
      expect(out.page, 4, reason: 'snap never changes the page');
      expect(out.xStartPct, 12);
      expect(out.xEndPct, 55);
      expect(out.yStartPct, 25);
      expect(out.yEndPct, 65);
    });

    test('Req 9.3 — an unchanged (echoed-back) response keeps the drawn box',
        () async {
      final QuestionSegment drawn = _drawn(x0: 10, x1: 60, y0: 20, y1: 70);
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 10, x1: 60, y0: 20, y1: 70), // echoed back
      );
      final intercept = buildSnapInterceptor(
        apiClient: h.client,
        jobId: () => 'job-1',
        enabled: () => true,
      );

      final QuestionSegment out = await intercept(drawn);
      expect(out.xStartPct, drawn.xStartPct);
      expect(out.xEndPct, drawn.xEndPct);
      expect(out.yStartPct, drawn.yStartPct);
      expect(out.yEndPct, drawn.yEndPct);
      expect(out.page, drawn.page);
    });

    test('Req 9.4 — an error response keeps the drawn box unchanged', () async {
      final QuestionSegment drawn = _drawn(x0: 10, x1: 60, y0: 20, y1: 70);
      final h = _client(
        statusCode: 500,
        body: jsonEncode(<String, dynamic>{'detail': 'snap failed'}),
      );
      final intercept = buildSnapInterceptor(
        apiClient: h.client,
        jobId: () => 'job-1',
        enabled: () => true,
      );

      final QuestionSegment out = await intercept(drawn);
      expect(out.xStartPct, drawn.xStartPct);
      expect(out.xEndPct, drawn.xEndPct);
      expect(out.yStartPct, drawn.yStartPct);
      expect(out.yEndPct, drawn.yEndPct);
      expect(out.page, drawn.page);
    });

    test('Snap off — commits verbatim and makes NO request', () async {
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 99, x1: 99, y0: 99, y1: 99),
      );
      final intercept = buildSnapInterceptor(
        apiClient: h.client,
        jobId: () => 'job-1',
        enabled: () => false,
      );

      final QuestionSegment drawn = _drawn();
      final QuestionSegment out = await intercept(drawn);
      expect(h.adapter.requestCount, 0, reason: 'no /api/snap call when off');
      expect(out.xStartPct, drawn.xStartPct);
      expect(out.xEndPct, drawn.xEndPct);
    });

    test('empty jobId — commits verbatim and makes NO request', () async {
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 99, x1: 99, y0: 99, y1: 99),
      );
      final intercept = buildSnapInterceptor(
        apiClient: h.client,
        jobId: () => '', // no session loaded
        enabled: () => true,
      );

      final QuestionSegment drawn = _drawn();
      final QuestionSegment out = await intercept(drawn);
      expect(h.adapter.requestCount, 0);
      expect(out.xEndPct, drawn.xEndPct);
    });
  });

  group('ReviewController snap wiring (Req 9)', () {
    AnalyzeResponse analyze({String jobId = 'job-1'}) => AnalyzeResponse(
          jobId: jobId,
          totalPages: 1,
          methodUsed: 'text',
          pages: <PageInfo>[
            const PageInfo(
              page: 1,
              widthPt: 600,
              heightPt: 800,
              previewUrl: '/api/preview/1.png',
            ),
          ],
          items: const <AnalyzedItem>[],
          notes: const <ReviewNote>[],
          needsReview: false,
          answerKeyCount: 0,
        );

    test('attachSnap tightens the committed box on box-end (Req 9.1/9.2)',
        () async {
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 15, x1: 45, y0: 18, y1: 48),
      );
      final c = ReviewController(apiClient: h.client);
      addTearDown(c.dispose);
      c.loadFromManual(analyze(jobId: 'snap-job'));

      await c.commitDrawnSegment(_drawn(page: 1, x0: 10, x1: 50, y0: 10, y1: 50));

      // Request carried the session job id + drawn coordinates (Req 9.1).
      final Map<String, dynamic> sent =
          h.adapter.lastRequest!.data as Map<String, dynamic>;
      expect(sent['job_id'], 'snap-job');
      expect(sent['page'], 1);

      // The committed box adopted the tightened rect (Req 9.2).
      final QuestionSegment seg = c.items.single.segments.single;
      expect(seg.xStartPct, 15);
      expect(seg.xEndPct, 45);
      expect(seg.yStartPct, 18);
      expect(seg.yEndPct, 48);
    });

    test('snap error keeps the drawn box on commit (Req 9.4)', () async {
      final h = _client(
        statusCode: 500,
        body: jsonEncode(<String, dynamic>{'detail': 'boom'}),
      );
      final c = ReviewController(apiClient: h.client);
      addTearDown(c.dispose);
      c.loadFromManual(analyze());

      await c.commitDrawnSegment(_drawn(page: 1, x0: 10, x1: 50, y0: 10, y1: 50));

      final QuestionSegment seg = c.items.single.segments.single;
      expect(seg.xStartPct, 10);
      expect(seg.xEndPct, 50);
      expect(seg.yStartPct, 10);
      expect(seg.yEndPct, 50);
    });

    test('snapEnabled=false commits verbatim with no request', () async {
      final h = _client(
        statusCode: 200,
        body: _snapBody(x0: 99, x1: 99, y0: 99, y1: 99),
      );
      final c = ReviewController(apiClient: h.client);
      addTearDown(c.dispose);
      c.loadFromManual(analyze());
      c.snapEnabled = false;

      await c.commitDrawnSegment(_drawn(page: 1, x0: 10, x1: 50, y0: 10, y1: 50));

      expect(h.adapter.requestCount, 0);
      final QuestionSegment seg = c.items.single.segments.single;
      expect(seg.xStartPct, 10);
      expect(seg.xEndPct, 50);
    });

    test('Snap defaults on and toggleSnap flips it + notifies', () {
      final c = ReviewController();
      addTearDown(c.dispose);
      expect(c.snapEnabled, isTrue, reason: 'matches the web default checkbox');

      var notifications = 0;
      c.addListener(() => notifications++);
      c.toggleSnap();
      expect(c.snapEnabled, isFalse);
      expect(notifications, 1);
      c.snapEnabled = false; // no-op, already false
      expect(notifications, 1);
    });
  });
}
