// Unit tests for DownloadService — Task 7.1 (Req 11.1, 16.1–16.5).
//
// The service is exercised through its two injectable seams:
//   * a [SaveLocationResolver] standing in for the native Save-As dialog, and
//   * a [FileDownloader] standing in for the streamed `Dio.downloadUri`.
// This keeps the tests free of the platform file-dialog channel and the real
// filesystem while still verifying the orchestration the task owns:
//   - the suggested filename is forwarded to the dialog (16.1),
//   - on confirm the engine URL is joined onto Base_URL and streamed (16.2),
//   - a dialog cancel aborts with no download (16.4),
//   - a CancelToken cancel is a clean abort, not an error (16.4),
//   - failures surface a readable message / engine detail (16.5).
//
// A final test drives the REAL default streamed downloader through a fake Dio
// HttpClientAdapter that serves bytes as a stream, proving the path is written
// without buffering the whole body and that the file is removed on error.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart' show FileSaveLocation, XTypeGroup;
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';

void main() {
  group('DownloadService (injected seams)', () {
    late ApiClient apiClient;

    setUp(() {
      apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'));
    });

    test('forwards the suggested filename to the Save-As dialog (16.1)',
        () async {
      String? seenSuggested;
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async {
          seenSuggested = suggestedName;
          return const FileSaveLocation('/tmp/out.zip');
        },
        downloader: (uri, savePath,
                {CancelToken? cancelToken,
                ProgressCallback? onReceiveProgress}) async {},
      );

      await service.download(
        engineUrl: '/api/crop/download/job?kind=combined',
        suggestedName: 'questions.zip',
      );

      expect(seenSuggested, 'questions.zip');
    });

    test('joins the engine URL onto Base_URL and streams to the chosen path '
        '(16.2, 16.3)', () async {
      Uri? streamedUri;
      String? streamedPath;
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation('/chosen/combined.zip'),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          streamedUri = uri;
          streamedPath = savePath;
        },
      );

      final result = await service.download(
        engineUrl: '/api/crop/download/job?kind=combined',
        suggestedName: 'combined.zip',
      );

      expect(result.isSaved, isTrue);
      expect(result.path, '/chosen/combined.zip');
      expect(streamedPath, '/chosen/combined.zip');
      expect(streamedUri.toString(),
          'http://127.0.0.1:54321/api/crop/download/job?kind=combined');
    });

    test('an already-absolute engine URL is streamed unchanged (16.2)',
        () async {
      Uri? streamedUri;
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation('/chosen/file.pdf'),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          streamedUri = uri;
        },
      );

      await service.download(
        engineUrl: 'http://127.0.0.1:54321/api/tools/edit/download/e1',
        suggestedName: 'edited.pdf',
      );

      expect(streamedUri.toString(),
          'http://127.0.0.1:54321/api/tools/edit/download/e1');
    });

    test('cancelling the Save-As dialog aborts with no download (16.4)',
        () async {
      var downloaderCalled = false;
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            null, // user dismissed the dialog
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          downloaderCalled = true;
        },
      );

      final result = await service.download(
        engineUrl: '/api/crop/download/job',
        suggestedName: 'out.zip',
      );

      expect(result.isCancelled, isTrue);
      expect(result.path, isNull);
      expect(downloaderCalled, isFalse);
    });

    test('an empty chosen path is treated as a cancel (16.4)', () async {
      var downloaderCalled = false;
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation(''),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          downloaderCalled = true;
        },
      );

      final result = await service.download(
        engineUrl: '/api/crop/download/job',
        suggestedName: 'out.zip',
      );

      expect(result.isCancelled, isTrue);
      expect(downloaderCalled, isFalse);
    });

    test('a CancelToken cancel is a clean abort, not a failure (16.4)',
        () async {
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation('/chosen/out.zip'),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          throw DioException(
            requestOptions: RequestOptions(path: uri.toString()),
            type: DioExceptionType.cancel,
          );
        },
      );

      final result = await service.download(
        engineUrl: '/api/crop/download/job',
        suggestedName: 'out.zip',
        cancelToken: CancelToken(),
      );

      expect(result.isCancelled, isTrue);
      expect(result.path, isNull);
    });

    test('surfaces the engine {"detail": ...} body verbatim on failure (16.5)',
        () async {
      const detail = 'Job not found or expired';
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation('/chosen/out.zip'),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          final reqOpts = RequestOptions(path: uri.toString());
          throw DioException(
            requestOptions: reqOpts,
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: reqOpts,
              statusCode: 404,
              data: <String, dynamic>{'detail': detail},
            ),
          );
        },
      );

      await expectLater(
        service.download(
          engineUrl: '/api/crop/download/job',
          suggestedName: 'out.zip',
        ),
        throwsA(
          isA<DownloadException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', detail),
        ),
      );
    });

    test('surfaces a readable message for a transport failure (16.5)',
        () async {
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation('/chosen/out.zip'),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          throw DioException(
            requestOptions: RequestOptions(path: uri.toString()),
            type: DioExceptionType.connectionError,
          );
        },
      );

      await expectLater(
        service.download(
          engineUrl: '/api/crop/download/job',
          suggestedName: 'out.zip',
        ),
        throwsA(
          isA<DownloadException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message',
                  contains('Could not reach the Qpic engine')),
        ),
      );
    });

    test('wraps a disk error from the downloader as a readable failure (16.5)',
        () async {
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            const FileSaveLocation('/chosen/out.zip'),
        downloader: (uri, savePath,
            {CancelToken? cancelToken,
            ProgressCallback? onReceiveProgress}) async {
          throw const FileSystemException('disk full');
        },
      );

      await expectLater(
        service.download(
          engineUrl: '/api/crop/download/job',
          suggestedName: 'out.zip',
        ),
        throwsA(
          isA<DownloadException>()
              .having((e) => e.message, 'message', contains('Could not save')),
        ),
      );
    });
  });

  group('DownloadService default streamed downloader (real Dio)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('qpic_dl_test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('streams a multi-chunk body to the chosen path (16.2, 16.3)',
        () async {
      // Three chunks served as a stream — never delivered as a single buffer.
      final chunks = <Uint8List>[
        Uint8List.fromList(List<int>.filled(1024, 65)),
        Uint8List.fromList(List<int>.filled(1024, 66)),
        Uint8List.fromList(List<int>.filled(512, 67)),
      ];
      final total = chunks.fold<int>(0, (sum, c) => sum + c.length);

      final dio = Dio()
        ..httpClientAdapter = _StreamAdapter(
          statusCode: 200,
          chunks: chunks,
          headers: <String, List<String>>{
            Headers.contentLengthHeader: <String>['$total'],
          },
        );
      final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);

      final savePath = '${tempDir.path}/combined.zip';
      var lastReceived = 0;
      var lastTotal = -1;
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            FileSaveLocation(savePath),
      );

      final result = await service.download(
        engineUrl: '/api/crop/download/job?kind=combined',
        suggestedName: 'combined.zip',
        onProgress: (received, t) {
          lastReceived = received;
          lastTotal = t;
        },
      );

      expect(result.isSaved, isTrue);
      expect(result.path, savePath);
      final written = File(savePath);
      expect(written.existsSync(), isTrue);
      expect(written.lengthSync(), total);
      expect(lastReceived, total);
      expect(lastTotal, total);
    });

    test('leaves no file behind when the download fails (16.4, 16.5)',
        () async {
      final dio = Dio()
        ..httpClientAdapter = _StreamAdapter(
          statusCode: 404,
          chunks: <Uint8List>[
            Uint8List.fromList(utf8.encode('{"detail":"Job not found"}')),
          ],
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);

      final savePath = '${tempDir.path}/missing.zip';
      final service = DownloadService(
        apiClient,
        saveLocationResolver: ({
          required String suggestedName,
          required List<XTypeGroup> acceptedTypeGroups,
        }) async =>
            FileSaveLocation(savePath),
      );

      await expectLater(
        service.download(
          engineUrl: '/api/crop/download/job',
          suggestedName: 'missing.zip',
        ),
        throwsA(isA<DownloadException>()),
      );
      expect(File(savePath).existsSync(), isFalse);
    });
  });
}

/// A fake adapter that serves [chunks] as a multi-event response stream so the
/// real `Dio.download` path writes them to disk incrementally.
class _StreamAdapter implements HttpClientAdapter {
  _StreamAdapter({
    required this.statusCode,
    required this.chunks,
    this.headers = const <String, List<String>>{},
  });

  final int statusCode;
  final List<Uint8List> chunks;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.fromIterable(chunks),
      statusCode,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
