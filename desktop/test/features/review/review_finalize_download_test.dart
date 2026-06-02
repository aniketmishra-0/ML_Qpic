// Unit tests for finalize + download from the Review Canvas
// (Task 12.6 — Requirements 6.6, 11.1, 11.2, 11.3, 11.4, 11.5).
//
// These verify the ReviewController's finalize + download orchestration:
//   * finalize() builds a FinalizeRequest from the kept auto items plus
//     drawn/re-selected items (each with type + page-percentage region) and the
//     active tool's output config, and POSTs /api/finalize (6.6),
//   * the answer-sheet setting rides on the request's `answer_sheet` (11.5),
//   * on success a Combined download is always offered, with Questions-only /
//     Solutions-only only when the engine reported their URLs (11.1–11.3),
//   * downloads route through GET /api/crop/download/{job_id} with kind +
//     configured prefixes (11.4),
//   * an empty item set blocks finalize and sends nothing (7.5-style guard),
//   * an engine error surfaces the detail and retains the items so the user can
//     retry (7.7-style).
//
// The engine is faked with a capturing Dio HttpClientAdapter (no network); the
// DownloadService is driven through its injectable seams (no file dialog/disk).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup;
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart'
    show CropArchive;
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

/// A fake adapter that returns a fixed response and records the last request
/// (path, method, decoded JSON body).
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  RequestOptions? lastRequest;
  String? lastContentType;
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
    lastContentType = options.contentType;
    // /api/finalize sends a JSON body via `data` (Dio serializes it), so the
    // decoded request data is available directly on options.data.
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

/// Builds a ReviewController bound to an ApiClient that returns [body] with
/// [statusCode], and a DownloadService whose save/stream seams are recorded.
class _Harness {
  _Harness({required int statusCode, required String body}) {
    adapter = _CapturingAdapter(statusCode: statusCode, body: body);
    final dio = Dio()..httpClientAdapter = adapter;
    apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
    downloadService = DownloadService(
      apiClient,
      saveLocationResolver: ({
        required String suggestedName,
        required List<XTypeGroup> acceptedTypeGroups,
      }) async {
        seenSuggestedNames.add(suggestedName);
        return FileSaveLocation('/chosen/$suggestedName');
      },
      downloader: (uri, savePath,
          {CancelToken? cancelToken,
          ProgressCallback? onReceiveProgress}) async {
        streamedUris.add(uri);
        streamedPaths.add(savePath);
      },
    );
    controller = ReviewController(
      apiClient: apiClient,
      downloadService: downloadService,
    );
  }

  late final _CapturingAdapter adapter;
  late final ApiClient apiClient;
  late final DownloadService downloadService;
  late final ReviewController controller;

  final List<String> seenSuggestedNames = <String>[];
  final List<Uri> streamedUris = <Uri>[];
  final List<String> streamedPaths = <String>[];
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
  String jobId = 'fin-job',
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

String _cropBody({
  String jobId = 'fin-job',
  String? questionsUrl,
  String? solutionsUrl,
  int questionsCount = 0,
  int solutionsCount = 0,
  bool answerSheetIncluded = false,
}) {
  return jsonEncode(<String, dynamic>{
    'job_id': jobId,
    'total_questions': questionsCount + solutionsCount,
    'stitched_questions': 0,
    'method_used': 'text',
    'download_url': '/api/crop/download/$jobId',
    'questions_download_url': questionsUrl,
    'solutions_download_url': solutionsUrl,
    'questions_count': questionsCount,
    'solutions_count': solutionsCount,
    'answer_sheet_included': answerSheetIncluded,
    'answers_count': 0,
  });
}

void main() {
  group('finalize POSTs /api/finalize with kept items + output config (6.6)',
      () {
    test('builds the request body from items + the active tool output config',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(questionsCount: 2),
      );
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze(
        jobId: 'fin-job',
        answerKeyCount: 4,
        items: <AnalyzedItem>[
          _item(qNum: '1', source: 'auto'),
          _item(
            qNum: '2',
            source: 'manual',
            segments: <QuestionSegment>[_seg(x0: 5, x1: 60, y0: 20, y1: 70)],
          ),
        ],
      ));

      final ok = await h.controller.finalize(
        dpi: 300,
        padding: 30,
        questionPrefix: 'QQ',
        solutionPrefix: 'SS',
        startNumber: 5,
        imageFormat: 'jpg',
        jpgQuality: 80,
        answerSheet: true,
      );

      expect(ok, isTrue);
      final req = h.adapter.lastRequest;
      expect(req?.path, '/api/finalize');
      expect(req?.method, 'POST');

      final body = h.adapter.lastJsonBody!;
      expect(body['job_id'], 'fin-job');
      expect(body['dpi'], 300);
      expect(body['padding'], 30);
      expect(body['question_prefix'], 'QQ');
      expect(body['solution_prefix'], 'SS');
      expect(body['start_number'], 5);
      expect(body['image_format'], 'jpg');
      expect(body['jpg_quality'], 80);
      expect(body['answer_sheet'], true);

      final items = body['items'] as List<dynamic>;
      expect(items.length, 2);
      // Each item carries type + page-percentage region + source (6.6).
      final manual = items[1] as Map<String, dynamic>;
      expect(manual['q_num'], '2');
      expect(manual['is_solution'], false);
      expect(manual['source'], 'manual');
      final seg = (manual['segments'] as List<dynamic>).single
          as Map<String, dynamic>;
      expect(seg['x_start_pct'], 5);
      expect(seg['x_end_pct'], 60);
      expect(seg['y_start_pct'], 20);
      expect(seg['y_end_pct'], 70);
    });

    test('skips items left with zero segments', () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 1));
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[
          _item(qNum: '1', segments: <QuestionSegment>[_seg()]),
          _item(qNum: '2', segments: const <QuestionSegment>[]),
        ],
      ));

      await h.controller.finalize();

      final items = h.adapter.lastJsonBody!['items'] as List<dynamic>;
      expect(items.length, 1);
      expect((items.single as Map<String, dynamic>)['q_num'], '1');
    });

    test('answer_sheet defaults to the detected answer key when not overridden '
        '(11.5)', () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 1));
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze(answerKeyCount: 7));

      await h.controller.finalize();

      expect(h.adapter.lastJsonBody!['answer_sheet'], true);
    });

    test('answer_sheet override wins over the detected default (11.5)',
        () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 1));
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze(answerKeyCount: 7));

      await h.controller.finalize(answerSheet: false);

      expect(h.adapter.lastJsonBody!['answer_sheet'], false);
    });
  });

  group('empty item set blocks finalize (7.5-style guard)', () {
    test('no items → blocked, no request sent, prompt surfaced', () async {
      final h = _Harness(statusCode: 200, body: _cropBody());
      addTearDown(h.controller.dispose);
      h.controller.loadFromManual(_analyze(
        pages: <PageInfo>[_page(1)],
      )); // manual starts empty

      final ok = await h.controller.finalize();

      expect(ok, isFalse);
      expect(h.adapter.requestCount, 0);
      expect(h.controller.finalizeError, ReviewController.errNoItems);
      expect(h.controller.finalizeResult, isNull);
    });
  });

  group('engine error retains items and surfaces detail (7.7-style)', () {
    test('a 404 stores the detail and keeps the items for retry', () async {
      final h = _Harness(
        statusCode: 404,
        body: jsonEncode(<String, dynamic>{'detail': 'Job ID not found'}),
      );
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze(
        items: <AnalyzedItem>[_item(qNum: '1'), _item(qNum: '2')],
      ));

      final ok = await h.controller.finalize();

      expect(ok, isFalse);
      expect(h.controller.finalizeResult, isNull);
      expect(h.controller.finalizeError, 'Job ID not found');
      // Items retained so the user can retry (7.7).
      expect(h.controller.items.length, 2);
    });
  });

  group('download actions match reported archives (11.1–11.3)', () {
    test('only Combined is downloadable when no per-type URLs are reported',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(questionsCount: 3),
      );
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze());
      await h.controller.finalize();

      expect(h.controller.canDownload(CropArchive.combined), isTrue);
      expect(h.controller.canDownload(CropArchive.questions), isFalse);
      expect(h.controller.canDownload(CropArchive.solutions), isFalse);
    });

    test('per-type archives are downloadable only when their URL is non-null',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(
          questionsUrl: '/api/crop/download/fin-job?kind=questions',
          solutionsUrl: '/api/crop/download/fin-job?kind=solutions',
          questionsCount: 3,
          solutionsCount: 2,
        ),
      );
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze());
      await h.controller.finalize();

      expect(h.controller.canDownload(CropArchive.combined), isTrue);
      expect(h.controller.canDownload(CropArchive.questions), isTrue);
      expect(h.controller.canDownload(CropArchive.solutions), isTrue);
    });
  });

  group('downloads route through cropDownloadUri with kind + prefixes (11.4)',
      () {
    test('each archive uses kind + the prefixes the finalize was given',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(
          questionsUrl: '/api/crop/download/fin-job?kind=questions',
          solutionsUrl: '/api/crop/download/fin-job?kind=solutions',
          questionsCount: 3,
          solutionsCount: 2,
        ),
      );
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze());
      await h.controller.finalize(
        questionPrefix: 'QQ',
        solutionPrefix: 'SS',
      );

      // Combined → kind=combined with the configured prefixes.
      final combined = await h.controller.download(CropArchive.combined);
      expect(combined?.isSaved, isTrue);
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/fin-job'
            '?kind=combined&question_prefix=QQ&solution_prefix=SS',
      );
      expect(h.seenSuggestedNames.last, 'QQSScombined.zip');

      // Questions → kind=questions.
      final questions = await h.controller.download(CropArchive.questions);
      expect(questions?.isSaved, isTrue);
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/fin-job'
            '?kind=questions&question_prefix=QQ&solution_prefix=SS',
      );
      expect(h.seenSuggestedNames.last, 'QQ.zip');

      // Solutions → kind=solutions.
      final solutions = await h.controller.download(CropArchive.solutions);
      expect(solutions?.isSaved, isTrue);
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/fin-job'
            '?kind=solutions&question_prefix=QQ&solution_prefix=SS',
      );
      expect(h.seenSuggestedNames.last, 'SS.zip');
    });

    test('downloading before finalize / an unavailable archive is a no-op',
        () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 3));
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze());

      // Before finalize there is no result → no-op.
      expect(await h.controller.download(CropArchive.combined), isNull);

      await h.controller.finalize();
      // Solutions archive not reported → no-op.
      expect(await h.controller.download(CropArchive.solutions), isNull);
      expect(h.streamedUris, isEmpty);
    });
  });

  group('loading a new session clears stale finalize state', () {
    test('finalizeResult is cleared on the next load', () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 1));
      addTearDown(h.controller.dispose);
      h.controller.loadFromAnalyze(_analyze());
      await h.controller.finalize();
      expect(h.controller.finalizeResult, isNotNull);

      h.controller.loadFromAnalyze(_analyze(jobId: 'other-job'));
      expect(h.controller.finalizeResult, isNull);
      expect(h.controller.finalizeError, isNull);
      expect(h.controller.canDownload(CropArchive.combined), isFalse);
    });
  });

  group('guards against an unbound engine', () {
    test('finalize is a no-op when no engine is bound', () async {
      final c = ReviewController();
      addTearDown(c.dispose);
      c.loadFromAnalyze(_analyze());

      expect(await c.finalize(), isFalse);
      expect(c.finalizeResult, isNull);
    });
  });
}
