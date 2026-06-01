// Unit tests for the AutoCropController submit guards + non-Smart crop path
// (Task 9.2 — Requirements 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 11.1, 11.2, 11.3).
//
// These verify the controller behaves exactly as the task demands:
//   * pre-request guards block submission, send NO request, preserve entered
//     values, and surface the matching prompt when Questions is on with an
//     empty range (5.5), Solutions is on with an empty range (5.6), or both
//     toggles are off (5.7),
//   * a valid non-Smart submit POSTs /api/crop with the mapped query params +
//     multipart file (5.4),
//   * on success a download action is offered only for each archive the
//     CropResponse reports (combined always; questions/solutions when their
//     URLs are non-null) (5.9, 11.1–11.3),
//   * an engine error surfaces the `detail` verbatim (5.8),
//   * a valid Smart submit runs the guards but issues NO crop request (the
//     analyze entry is task 12.5).
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
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart';

/// A fake adapter that returns a fixed response and records the last request
/// (path, method, query string, content type).
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

/// Builds a controller whose ApiClient returns [body] with [statusCode], and a
/// DownloadService whose save/stream seams are recorded.
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
    controller = AutoCropController(
      apiClient: apiClient,
      downloadService: downloadService,
    );
  }

  late final _CapturingAdapter adapter;
  late final ApiClient apiClient;
  late final DownloadService downloadService;
  late final AutoCropController controller;

  final List<String> seenSuggestedNames = <String>[];
  final List<Uri> streamedUris = <Uri>[];
  final List<String> streamedPaths = <String>[];
}

String _cropBody({
  String? questionsUrl,
  String? solutionsUrl,
  int questionsCount = 0,
  int solutionsCount = 0,
  bool answerSheetIncluded = false,
}) {
  return jsonEncode(<String, dynamic>{
    'job_id': 'job-9',
    'total_questions': questionsCount + solutionsCount,
    'stitched_questions': 0,
    'method_used': 'text',
    'download_url': '/api/crop/download/job-9',
    'questions_download_url': questionsUrl,
    'solutions_download_url': solutionsUrl,
    'questions_count': questionsCount,
    'solutions_count': solutionsCount,
    'answer_sheet_included': answerSheetIncluded,
    'answers_count': 0,
  });
}

void main() {
  group('validateSubmission guards (Req 5.5, 5.6, 5.7)', () {
    test('both toggles off → ERR_NOTHING_SELECTED prompt', () {
      final c = AutoCropController()
        ..hasQuestions = false
        ..hasAnswers = false;
      expect(c.validateSubmission(), AutoCropController.errNothingSelected);
    });

    test('Questions on with empty range → question-pages prompt', () {
      final c = AutoCropController()
        ..hasAnswers = false
        ..hasQuestions = true
        ..questionPages = '   '; // whitespace only counts as empty
      expect(
        c.validateSubmission(),
        AutoCropController.errQuestionPagesRequired,
      );
    });

    test('Solutions on with empty range → answer-pages prompt', () {
      final c = AutoCropController()
        ..hasQuestions = false
        ..hasAnswers = true
        ..answerPages = '';
      expect(c.validateSubmission(), AutoCropController.errAnswerPagesRequired);
    });

    test('valid form (both ranges filled) → no prompt', () {
      final c = AutoCropController()
        ..questionPages = '1-5'
        ..answerPages = '7-10';
      expect(c.validateSubmission(), isNull);
    });
  });

  group('submit() blocks + preserves values, sends nothing (Req 5.5–5.7)', () {
    test('a guarded submit sends no request and keeps the entered values',
        () async {
      final h = _Harness(statusCode: 200, body: _cropBody());
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf')
        ..hasQuestions = true
        ..questionPages = '' // empty → blocked
        ..hasAnswers = true
        ..answerPages = '7-10';

      final ok = await h.controller.submit();

      expect(ok, isFalse);
      expect(h.adapter.requestCount, 0); // no request sent
      // Entered values preserved.
      expect(h.controller.questionPages, '');
      expect(h.controller.answerPages, '7-10');
      // Matching prompt surfaced.
      expect(
        h.controller.errorText,
        AutoCropController.errQuestionPagesRequired,
      );
      expect(h.controller.result, isNull);
    });

    test('nothing-selected submit sends no request and prompts', () async {
      final h = _Harness(statusCode: 200, body: _cropBody());
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..hasQuestions = false
        ..hasAnswers = false;

      final ok = await h.controller.submit();

      expect(ok, isFalse);
      expect(h.adapter.requestCount, 0);
      expect(h.controller.errorText, AutoCropController.errNothingSelected);
    });
  });

  group('submit() valid non-Smart crop (Req 5.4)', () {
    test('POSTs /api/crop with the mapped query params + multipart file',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(questionsCount: 3, solutionsCount: 0),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1, 2, 3], filename: 'paper.pdf')
        ..hasQuestions = true
        ..questionPages = '1-5'
        ..hasAnswers = false
        ..numbering = NumberingMode.qOnly
        ..onlineMode = true
        ..answerSheet = false
        ..dpi = 300
        ..padding = 40
        ..startNumber = 5
        ..questionPrefix = 'QQ'
        ..solutionPrefix = 'SS';

      final ok = await h.controller.submit();

      expect(ok, isTrue);
      final req = h.adapter.lastRequest;
      expect(req?.path, '/api/crop');
      expect(req?.method, 'POST');
      expect(h.adapter.lastContentType, contains('multipart/form-data'));

      final q = req!.queryParameters;
      expect(q['dpi'], 300);
      expect(q['padding'], 40);
      expect(q['marker_style'], 'q');
      expect(q['has_questions'], true);
      expect(q['question_pages'], '1-5');
      expect(q['has_answers'], false);
      // answer_pages omitted when Solutions is off (no stale range leaks).
      expect(q.containsKey('answer_pages'), isFalse);
      expect(q['question_prefix'], 'QQ');
      expect(q['solution_prefix'], 'SS');
      expect(q['start_number'], 5);
      expect(q['image_format'], 'png');
      expect(q['jpg_quality'], 90);
      expect(q['use_ai'], true);
      expect(q['answer_sheet'], false);
    });

    test('omits question_pages when Questions is off', () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(solutionsCount: 2),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..hasQuestions = false
        ..hasAnswers = true
        ..answerPages = '7-10';

      await h.controller.submit();

      final q = h.adapter.lastRequest!.queryParameters;
      expect(q.containsKey('question_pages'), isFalse);
      expect(q['answer_pages'], '7-10');
    });
  });

  group('Smart mode runs guards but issues no crop (analyze is task 12.5)', () {
    test('valid Smart submit sends no /api/crop request', () async {
      final h = _Harness(statusCode: 200, body: _cropBody());
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..questionPages = '1-5'
        ..answerPages = '7-10';

      final ok = await h.controller.submit();

      expect(ok, isFalse); // no direct crop happened
      expect(h.adapter.requestCount, 0);
      expect(h.controller.errorText, isNull); // guards passed
    });

    test('invalid Smart submit still blocks with the matching prompt',
        () async {
      final h = _Harness(statusCode: 200, body: _cropBody());
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..smartMode = true
        ..hasQuestions = true
        ..questionPages = ''
        ..hasAnswers = false;

      await h.controller.submit();

      expect(h.adapter.requestCount, 0);
      expect(
        h.controller.errorText,
        AutoCropController.errQuestionPagesRequired,
      );
    });
  });

  group('error handling surfaces engine detail (Req 5.8)', () {
    test('stores the {"detail": ...} message on a 4xx and keeps no result',
        () async {
      final h = _Harness(
        statusCode: 422,
        body: jsonEncode(<String, dynamic>{
          'detail': 'No questions detected in this PDF',
        }),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..questionPages = '1-5'
        ..answerPages = '7-10';

      final ok = await h.controller.submit();

      expect(ok, isFalse);
      expect(h.controller.result, isNull);
      expect(h.controller.errorText, 'No questions detected in this PDF');
    });
  });

  group('download actions match reported archives (Req 5.9, 11.1–11.3)', () {
    test('only Combined is downloadable when no per-type URLs are reported',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(questionsCount: 3),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..questionPages = '1-5'
        ..answerPages = '7-10';
      await h.controller.submit();

      expect(h.controller.canDownload(CropArchive.combined), isTrue);
      expect(h.controller.canDownload(CropArchive.questions), isFalse);
      expect(h.controller.canDownload(CropArchive.solutions), isFalse);
    });

    test('per-type archives are downloadable only when their URL is non-null',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(
          questionsUrl: '/api/crop/download/job-9?kind=questions',
          solutionsUrl: '/api/crop/download/job-9?kind=solutions',
          questionsCount: 3,
          solutionsCount: 2,
        ),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..questionPages = '1-5'
        ..answerPages = '7-10';
      await h.controller.submit();

      expect(h.controller.canDownload(CropArchive.combined), isTrue);
      expect(h.controller.canDownload(CropArchive.questions), isTrue);
      expect(h.controller.canDownload(CropArchive.solutions), isTrue);
    });

    test('downloads route through cropDownloadUri with kind + prefixes',
        () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(
          questionsUrl: '/api/crop/download/job-9?kind=questions',
          solutionsUrl: '/api/crop/download/job-9?kind=solutions',
          questionsCount: 3,
          solutionsCount: 2,
        ),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..questionPages = '1-5'
        ..answerPages = '7-10'
        // Configured prefixes drive the download query (Req 11.4).
        ..questionPrefix = 'QQ'
        ..solutionPrefix = 'SS';
      await h.controller.submit();

      // Combined → kind=combined with the configured prefixes.
      final combined = await h.controller.download(CropArchive.combined);
      expect(combined?.isSaved, isTrue);
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/job-9'
            '?kind=combined&question_prefix=QQ&solution_prefix=SS',
      );
      // Filename mirrors the engine's prefix-based combined name.
      expect(h.seenSuggestedNames.last, 'QQSScombined.zip');

      // Questions → kind=questions with the configured prefixes.
      final questions = await h.controller.download(CropArchive.questions);
      expect(questions?.isSaved, isTrue);
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/job-9'
            '?kind=questions&question_prefix=QQ&solution_prefix=SS',
      );
      expect(h.seenSuggestedNames.last, 'QQ.zip');

      // Solutions → kind=solutions with the configured prefixes.
      final solutions = await h.controller.download(CropArchive.solutions);
      expect(solutions?.isSaved, isTrue);
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/job-9'
            '?kind=solutions&question_prefix=QQ&solution_prefix=SS',
      );
      expect(h.seenSuggestedNames.last, 'SS.zip');
    });

    test('downloading an unavailable archive is a no-op', () async {
      final h = _Harness(
        statusCode: 200,
        body: _cropBody(questionsCount: 3),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1], filename: 'in.pdf')
        ..questionPages = '1-5'
        ..answerPages = '7-10';
      await h.controller.submit();

      final result = await h.controller.download(CropArchive.solutions);
      expect(result, isNull);
      expect(h.streamedUris, isEmpty);
    });
  });
}
