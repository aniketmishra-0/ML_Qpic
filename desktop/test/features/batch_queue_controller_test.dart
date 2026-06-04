import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart' show FileSaveLocation, XFile, XTypeGroup;
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/features/auto_crop/batch_queue_controller.dart';
import 'package:qpic_desktop/models/crop.dart';

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
    requestCount++;
    lastRequest = options;
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: ['application/json'],
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
    controller = BatchQueueController();
  }

  late final _CapturingAdapter adapter;
  late final ApiClient apiClient;
  late final DownloadService downloadService;
  late final BatchQueueController controller;

  final List<String> seenSuggestedNames = <String>[];
  final List<Uri> streamedUris = <Uri>[];
  final List<String> streamedPaths = <String>[];
}

String _cropBody({
  String? questionsUrl,
  String? solutionsUrl,
  int questionsCount = 0,
  int solutionsCount = 0,
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
    'answer_sheet_included': false,
    'answers_count': 0,
  });
}

void main() {
  group('BatchQueueController initialization', () {
    test('starts with an empty queue', () {
      final q = BatchQueueController();
      expect(q.items, isEmpty);
      expect(q.isProcessing, isFalse);
      expect(q.progress, 0.0);
      expect(q.currentIndex, 0);
      expect(q.hasSuccessfulItems, isFalse);
    });
  });

  group('BatchQueueController Item Management', () {
    test('addFiles adds unique files to queue and notifies listeners', () async {
      final q = BatchQueueController();
      var notifications = 0;
      q.addListener(() => notifications++);

      final file1 = XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.pdf', path: 'a.pdf');
      final file2 = XFile.fromData(Uint8List.fromList([4, 5]), name: 'b.pdf', path: 'b.pdf');

      await q.addFiles([file1, file2]);

      expect(q.items.length, 2);
      expect(q.items[0].file.name, 'a.pdf');
      expect(q.items[1].file.name, 'b.pdf');
      expect(notifications, 1);
    });

    test('addFiles ignores duplicate paths', () async {
      final q = BatchQueueController();
      final file1 = XFile.fromData(Uint8List.fromList([1]), name: 'a.pdf', path: 'a.pdf');
      final file2 = XFile.fromData(Uint8List.fromList([2]), name: 'a.pdf', path: 'a.pdf');

      await q.addFiles([file1]);
      await q.addFiles([file2]);

      expect(q.items.length, 1);
    });

    test('removeFile deletes item from queue', () async {
      final q = BatchQueueController();
      final file1 = XFile.fromData(Uint8List.fromList([1]), name: 'a.pdf', path: 'a.pdf');
      final file2 = XFile.fromData(Uint8List.fromList([2]), name: 'b.pdf', path: 'b.pdf');

      await q.addFiles([file1, file2]);
      q.removeFile(0);

      expect(q.items.length, 1);
      expect(q.items[0].file.name, 'b.pdf');
    });

    test('clear resets the queue state', () async {
      final q = BatchQueueController();
      final file1 = XFile.fromData(Uint8List.fromList([1]), name: 'a.pdf', path: 'a.pdf');
      await q.addFiles([file1]);

      q.clear();
      expect(q.items, isEmpty);
      expect(q.progress, 0.0);
    });
  });

  group('BatchQueueController sequential processing', () {
    test('processAll runs crop sequentially for all items', () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 2));
      final file1 = XFile.fromData(Uint8List.fromList([1]), name: 'file1.pdf', path: 'file1.pdf');
      final file2 = XFile.fromData(Uint8List.fromList([2]), name: 'file2.pdf', path: 'file2.pdf');

      await h.controller.addFiles([file1, file2]);

      final processFuture = h.controller.processAll(
        client: h.apiClient,
        dpi: 200,
        padding: 20,
        markerStyle: 'auto',
        hasQuestions: true,
        questionPages: '1',
        hasAnswers: false,
        answerPages: null,
        skipPages: null,
        questionPrefix: 'Q',
        solutionPrefix: 'S',
        startNumber: 1,
        imageFormat: 'png',
        jpgQuality: 90,
        useAi: false,
        answerSheet: false,
        layoutColumns: 'auto',
        binarize: false,
        contrast: 1.0,
        brightness: 1.0,
        watermarkThreshold: 255,
        deskew: false,
        customRegex: '',
        confidence: 0.5,
      );

      await processFuture;

      expect(h.controller.isProcessing, isFalse);
      expect(h.controller.progress, 1.0);
      expect(h.controller.items[0].status, BatchItemStatus.done);
      expect(h.controller.items[1].status, BatchItemStatus.done);
      expect(h.controller.items[0].result, isNotNull);
      expect(h.controller.items[1].result, isNotNull);
      expect(h.adapter.requestCount, 2);
    });

    test('processAll sets items to error state on failure and continues', () async {
      final h = _Harness(statusCode: 500, body: 'Internal Server Error');
      final file1 = XFile.fromData(Uint8List.fromList([1]), name: 'file1.pdf', path: 'file1.pdf');

      await h.controller.addFiles([file1]);

      await h.controller.processAll(
        client: h.apiClient,
        dpi: 200,
        padding: 20,
        markerStyle: 'auto',
        hasQuestions: true,
        questionPages: '1',
        hasAnswers: false,
        answerPages: null,
        skipPages: null,
        questionPrefix: 'Q',
        solutionPrefix: 'S',
        startNumber: 1,
        imageFormat: 'png',
        jpgQuality: 90,
        useAi: false,
        answerSheet: false,
        layoutColumns: 'auto',
        binarize: false,
        contrast: 1.0,
        brightness: 1.0,
        watermarkThreshold: 255,
        deskew: false,
        customRegex: '',
        confidence: 0.5,
      );

      expect(h.controller.items[0].status, BatchItemStatus.error);
      expect(h.controller.items[0].errorText, contains('ApiException'));
    });
  });

  group('BatchQueueController downloads', () {
    test('downloadItem triggers download resolved with prefixes', () async {
      final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 2));
      final file1 = XFile.fromData(Uint8List.fromList([1]), name: 'file1.pdf', path: 'file1.pdf');

      await h.controller.addFiles([file1]);
      await h.controller.processAll(
        client: h.apiClient,
        dpi: 200,
        padding: 20,
        markerStyle: 'auto',
        hasQuestions: true,
        questionPages: '1',
        hasAnswers: false,
        answerPages: null,
        skipPages: null,
        questionPrefix: 'Q',
        solutionPrefix: 'S',
        startNumber: 1,
        imageFormat: 'png',
        jpgQuality: 90,
        useAi: false,
        answerSheet: false,
        layoutColumns: 'auto',
        binarize: false,
        contrast: 1.0,
        brightness: 1.0,
        watermarkThreshold: 255,
        deskew: false,
        customRegex: '',
        confidence: 0.5,
      );

      await h.controller.downloadItem(0, h.downloadService, 'QQ', 'SS');

      expect(h.seenSuggestedNames.last, 'file1_QQSScombined.zip');
      expect(
        h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/job-9?kind=combined&question_prefix=QQ&solution_prefix=SS',
      );
    });
  });
}
