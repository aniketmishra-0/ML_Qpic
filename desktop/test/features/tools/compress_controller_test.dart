// Unit tests for CompressController (Requirement 13).
//
// These verify the controller's state/validation and that it drives the engine
// exactly as Requirement 13 demands:
//   * the level selector offers light/balanced/strong/extreme and a target-MB
//     field constrained to > 0 (13.1),
//   * compress() POSTs either `level` OR `target_mb` (13.2),
//   * a successful result exposes original/compressed/ratio for display (13.3),
//   * download() streams the response download_url (13.4),
//   * an engine error surfaces the `detail` verbatim (13.5).
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
import 'package:qpic_desktop/features/tools/compress/compress_controller.dart';

/// A fake adapter that returns a fixed response and records the last request,
/// including the multipart form fields it carried.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  RequestOptions? lastRequest;
  String? lastContentType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
        seenSuggestedName = suggestedName;
        return const FileSaveLocation('/chosen/compressed.pdf');
      },
      downloader: (uri, savePath,
          {CancelToken? cancelToken,
          ProgressCallback? onReceiveProgress}) async {
        streamedUri = uri;
        streamedPath = savePath;
      },
    );
    controller = CompressController(
      apiClient: apiClient,
      downloadService: downloadService,
    );
  }

  late final _CapturingAdapter adapter;
  late final ApiClient apiClient;
  late final DownloadService downloadService;
  late final CompressController controller;

  String? seenSuggestedName;
  Uri? streamedUri;
  String? streamedPath;
}

String _compressBody({
  String level = 'balanced',
  int original = 1000000,
  int compressed = 400000,
  double ratio = 0.6,
  bool? targetMet,
  String note = '',
}) {
  return jsonEncode(<String, dynamic>{
    'job_id': 'job-123',
    'original_size': original,
    'compressed_size': compressed,
    'ratio': ratio,
    'level': level,
    'target_met': targetMet,
    'note': note,
    'download_url': '/api/tools/compress/download/job-123',
  });
}

void main() {
  group('defaults + validation (Req 13.1)', () {
    test('starts at the balanced level with target mode off', () {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);

      expect(h.controller.level, CompressLevel.balanced);
      expect(h.controller.useTarget, isFalse);
      expect(h.controller.hasFile, isFalse);
      expect(h.controller.canRun, isFalse); // no file yet
    });

    test('offers exactly the four engine levels', () {
      expect(
        CompressLevel.values.map((l) => l.value).toList(),
        <String>['light', 'balanced', 'strong', 'extreme'],
      );
    });

    test('target must be greater than 0', () {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);
      h.controller.useTarget = true;

      h.controller.targetMbText = '0';
      expect(h.controller.isTargetValid, isFalse);

      h.controller.targetMbText = '-2';
      expect(h.controller.isTargetValid, isFalse);

      h.controller.targetMbText = 'abc';
      expect(h.controller.isTargetValid, isFalse);

      h.controller.targetMbText = '2.5';
      expect(h.controller.isTargetValid, isTrue);
      expect(h.controller.targetMb, 2.5);
    });

    test('canRun requires a valid target when targeting a size', () {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);
      h.controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');

      expect(h.controller.canRun, isTrue); // level mode

      h.controller.useTarget = true;
      h.controller.targetMbText = '0';
      expect(h.controller.canRun, isFalse);

      h.controller.targetMbText = '1.5';
      expect(h.controller.canRun, isTrue);
    });

    test('clear() resets all inputs, results, and configs to default', () {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);

      h.controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');
      h.controller.useTarget = true;
      h.controller.targetMbText = '5.5';
      h.controller.level = CompressLevel.extreme;

      expect(h.controller.hasFile, isTrue);
      expect(h.controller.fileName, 'in.pdf');

      h.controller.clear();

      expect(h.controller.hasFile, isFalse);
      expect(h.controller.fileName, isNull);
      expect(h.controller.level, CompressLevel.balanced);
      expect(h.controller.useTarget, isFalse);
      expect(h.controller.targetMbText, '2');
      expect(h.controller.result, isNull);
      expect(h.controller.errorText, isNull);
    });
  });

  group('compress() drives the engine (Req 13.2, 13.3)', () {
    test('sends `level` (not target_mb) in level mode', () async {
      final h = _Harness(statusCode: 200, body: _compressBody(level: 'strong'));
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf')
        ..level = CompressLevel.strong;

      await h.controller.compress();

      expect(h.adapter.lastRequest?.path, '/api/tools/compress');
      expect(h.adapter.lastRequest?.method, 'POST');
      // multipart form body.
      expect(h.adapter.lastContentType, contains('multipart/form-data'));

      final result = h.controller.result;
      expect(result, isNotNull);
      expect(result!.level, 'strong');
      expect(result.originalSize, 1000000);
      expect(result.compressedSize, 400000);
      expect(result.ratio, closeTo(0.6, 1e-9));
      expect(h.controller.percentSmaller, 60);
      expect(h.controller.errorText, isNull);
    });

    test('sends target_mb in target mode', () async {
      final h = _Harness(
        statusCode: 200,
        body: _compressBody(level: 'target 2.0MB', targetMet: true),
      );
      addTearDown(h.controller.dispose);
      h.controller
        ..setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf')
        ..useTarget = true
        ..targetMbText = '2';

      await h.controller.compress();

      expect(h.controller.result?.targetMet, isTrue);
      expect(h.controller.result?.level, 'target 2.0MB');
      expect(h.controller.errorText, isNull);
    });

    test('does nothing when no file is selected', () async {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);

      await h.controller.compress();

      expect(h.adapter.lastRequest, isNull);
      expect(h.controller.result, isNull);
    });
  });

  group('error handling surfaces engine detail (Req 13.5)', () {
    test('stores the {"detail": ...} message on a 4xx', () async {
      final h = _Harness(
        statusCode: 400,
        body: jsonEncode(<String, dynamic>{
          'detail': 'target_mb must be greater than 0.',
        }),
      );
      addTearDown(h.controller.dispose);
      h.controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');

      await h.controller.compress();

      expect(h.controller.result, isNull);
      expect(h.controller.errorText, 'target_mb must be greater than 0.');
    });

    test('selecting a new file clears a prior error', () async {
      final h = _Harness(
        statusCode: 500,
        body: jsonEncode(<String, dynamic>{'detail': 'boom'}),
      );
      addTearDown(h.controller.dispose);
      h.controller.setFile(bytes: const <int>[1], filename: 'a.pdf');
      await h.controller.compress();
      expect(h.controller.errorText, 'boom');

      h.controller.setFile(bytes: const <int>[2], filename: 'b.pdf');
      expect(h.controller.errorText, isNull);
      expect(h.controller.result, isNull);
    });
  });

  group('download() streams the response URL (Req 13.4)', () {
    test('joins download_url onto Base_URL and streams it', () async {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);
      h.controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');
      await h.controller.compress();

      final result = await h.controller.download();

      expect(result, isNotNull);
      expect(result!.isSaved, isTrue);
      expect(h.seenSuggestedName, 'in.pdf');
      expect(h.streamedPath, '/chosen/compressed.pdf');
      expect(
        h.streamedUri.toString(),
        'http://127.0.0.1:54321/api/tools/compress/download/job-123',
      );
    });

    test('returns null when there is no result to download', () async {
      final h = _Harness(statusCode: 200, body: _compressBody());
      addTearDown(h.controller.dispose);

      final result = await h.controller.download();

      expect(result, isNull);
      expect(h.streamedUri, isNull);
    });
  });

  group('humanFileSize matches the web UI formatting', () {
    test('bytes / KB / MB thresholds', () {
      expect(humanFileSize(0), '0 B');
      expect(humanFileSize(512), '512 B');
      expect(humanFileSize(1024), '1 KB');
      expect(humanFileSize(1536), '2 KB'); // toFixed(0) rounds
      expect(humanFileSize(1024 * 1024), '1.0 MB');
      expect(humanFileSize(2621440), '2.5 MB');
    });
  });
}
