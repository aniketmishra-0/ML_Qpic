import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  RequestOptions? lastRequest;
  Map<String, dynamic>? lastQueryParams;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    lastRequest = options;
    lastQueryParams = options.queryParameters;
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

class _Harness {
  _Harness({required int statusCode, required String body}) {
    adapter = _CapturingAdapter(statusCode: statusCode, body: body);
    final dio = Dio()..httpClientAdapter = adapter;
    apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
    controller = ReviewController(apiClient: apiClient);
  }

  late final _CapturingAdapter adapter;
  late final ApiClient apiClient;
  late final ReviewController controller;
}

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '/api/analyze/job/page/$n',
    );

QuestionSegment _seg({
  int page = 1,
  double x0 = 10,
  double x1 = 40,
  double y0 = 10,
  double y1 = 40,
}) =>
    QuestionSegment(
      page: page,
      xStartPct: x0,
      xEndPct: x1,
      yStartPct: y0,
      yEndPct: y1,
    );

AnalyzedItem _item({
  String qNum = '1',
  bool isSolution = false,
  String source = 'auto',
  List<QuestionSegment>? segments,
}) =>
    AnalyzedItem(
      qNum: qNum,
      isSolution: isSolution,
      source: source,
      segments: segments ?? <QuestionSegment>[_seg()],
    );

AnalyzeResponse _analyze({
  String jobId = 'test-job',
  int answerKeyCount = 0,
  List<PageInfo>? pages,
  List<AnalyzedItem>? items,
}) =>
    AnalyzeResponse(
      jobId: jobId,
      totalPages: (pages ?? <PageInfo>[_page(1)]).length,
      methodUsed: 'text',
      pages: pages ?? <PageInfo>[_page(1)],
      items: items ?? <AnalyzedItem>[_item()],
      notes: const <ReviewNote>[],
      needsReview: false,
      answerKeyCount: answerKeyCount,
    );

void main() {
  group('Auto Detect on-demand review session API integration', () {
    test(
        'runAutoDetect for pageOnly sends page query param and merges segments',
        () async {
      final detectedJson = jsonEncode(<Map<String, dynamic>>[
        _item(
                qNum: '1',
                segments: <QuestionSegment>[_seg(page: 2, y0: 15, y1: 35)])
            .toJson(),
        _item(
                qNum: '3',
                segments: <QuestionSegment>[_seg(page: 2, y0: 50, y1: 70)])
            .toJson(),
      ]);

      final h = _Harness(statusCode: 200, body: detectedJson);
      addTearDown(h.controller.dispose);

      h.controller.loadFromAnalyze(_analyze(
        jobId: 'detect-job',
        pages: <PageInfo>[_page(1), _page(2)],
        items: <AnalyzedItem>[
          _item(qNum: '1', segments: <QuestionSegment>[
            _seg(page: 1, y0: 10, y1: 30),
            _seg(page: 2, y0: 10, y1: 30),
          ]),
          _item(qNum: '2', segments: <QuestionSegment>[
            _seg(page: 2, y0: 40, y1: 60),
          ]),
        ],
      ));

      // Go to page 2
      h.controller.gotoPageIndex(1);
      expect(h.controller.currentPageNumber, 2);

      var notifies = 0;
      h.controller.addListener(() => notifies++);

      await h.controller
          .runAutoDetect(pageOnly: true, useAi: true, markerStyle: 'numbered');

      // Verify request parameters
      expect(h.adapter.requestCount, 1);
      final req = h.adapter.lastRequest;
      expect(req?.path, '/api/crop/detect-job/auto-detect');
      expect(req?.method, 'POST');
      expect(h.adapter.lastQueryParams?['page'], 2);
      expect(h.adapter.lastQueryParams?['use_ai'], true);
      expect(h.adapter.lastQueryParams?['marker_style'], 'numbered');

      // Verify state was merged
      expect(h.controller.items.length, 2,
          reason: 'Q2 removed, Q3 added, Q1 kept');

      final q1 = h.controller.items.firstWhere((it) => it.qNum == '1');
      expect(q1.segments.length, 2);
      expect(q1.segments.any((s) => s.page == 1 && s.yStartPct == 10), isTrue,
          reason: 'page 1 segment preserved');
      expect(q1.segments.any((s) => s.page == 2 && s.yStartPct == 15), isTrue,
          reason: 'page 2 segment replaced');

      expect(h.controller.items.any((it) => it.qNum == '2'), isFalse);
      expect(h.controller.items.any((it) => it.qNum == '3'), isTrue);

      expect(notifies, greaterThanOrEqualTo(2),
          reason: 'notified during loading and when complete');
    });

    test(
        'runAutoDetect for all pages does not send page parameter and replaces all items',
        () async {
      final detectedJson = jsonEncode(<Map<String, dynamic>>[
        _item(qNum: '5').toJson(),
      ]);

      final h = _Harness(statusCode: 200, body: detectedJson);
      addTearDown(h.controller.dispose);

      h.controller.loadFromAnalyze(_analyze(
        jobId: 'detect-job',
        items: <AnalyzedItem>[_item(qNum: '1'), _item(qNum: '2')],
      ));

      await h.controller.runAutoDetect(pageOnly: false);

      expect(h.adapter.requestCount, 1);
      expect(h.adapter.lastQueryParams?['page'], isNull);

      expect(h.controller.items.length, 1);
      expect(h.controller.items.single.qNum, '5');
    });
  });
}
