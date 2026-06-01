// Unit tests for EditController in-place edit / apply / OCR / download
// (Task 18.2 — Req 15.4, 15.5, 15.6, 15.7).
//
// These complement edit_controller_test.dart (which covers the open flow). A
// path-routing fake HttpClientAdapter feeds the controller canned engine
// responses for `edit/open`, `edit/apply`, `edit/ocr`, and `edit/{job}/state`
// so no real network is used. The download path is exercised with an injected
// DownloadService whose Save-As + streamed-download collaborators are fakes, so
// no native file-dialog channel is touched.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup;
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/features/tools/edit/edit_controller.dart';
import 'package:qpic_desktop/models/tools.dart';

/// A canned engine response keyed by what the request matched.
class _Reply {
  const _Reply(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// Routes each request to a canned reply based on its path (and method), and
/// records the most recent request so tests can assert the endpoint hit and the
/// JSON body sent.
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this._route);

  /// Returns the reply for a given (method, path), or null to 404.
  final _Reply? Function(String method, String path) _route;

  RequestOptions? lastRequest;
  String? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final bytes = <int>[];
      for (final c in chunks) {
        bytes.addAll(c);
      }
      lastBody = utf8.decode(bytes, allowMalformed: true);
    } else if (options.data is String) {
      lastBody = options.data as String;
    } else {
      lastBody = null;
    }

    final reply = _route(options.method, options.path) ??
        const _Reply(404, '{"detail": "not found"}');
    return ResponseBody.fromString(
      reply.body,
      reply.statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const String _openBodyWithText = '''
{
  "job_id": "job-1",
  "has_text": true,
  "pages": [
    {"page": 1, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/job-1/page/1"}
  ],
  "spans": [
    {"id": "p1_s0", "page": 1, "text": "Hello", "bbox": [10.0, 20.0, 100.0, 40.0], "font": "Helvetica", "size": 12.0, "color": 1118481, "bold": false, "italic": false},
    {"id": "p1_s1", "page": 1, "text": "World", "bbox": [10.0, 60.0, 120.0, 80.0], "font": "Times", "size": 14.0, "color": 0, "bold": true, "italic": false}
  ]
}
''';

const String _openBodyNoText = '''
{
  "job_id": "scan-1",
  "has_text": false,
  "pages": [
    {"page": 1, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/scan-1/page/1"}
  ],
  "spans": []
}
''';

const String _applyOkBody = '''
{
  "job_id": "job-1",
  "edits_applied": 1,
  "download_url": "/api/tools/edit/download/job-1"
}
''';

const String _ocrOkBody = '''
{
  "job_id": "ocr-9",
  "pages_ocred": 3,
  "languages": "eng+hin",
  "note": "Made 3 pages searchable.",
  "download_url": "/api/tools/edit/download/ocr-9"
}
''';

const String _stateAfterOcrBody = '''
{
  "job_id": "ocr-9",
  "has_text": true,
  "pages": [
    {"page": 1, "width": 612.0, "height": 792.0, "preview_url": "/api/tools/edit/ocr-9/page/1"}
  ],
  "spans": [
    {"id": "o1_s0", "page": 1, "text": "Recognized", "bbox": [5.0, 5.0, 90.0, 25.0], "font": "Helvetica", "size": 11.0, "color": 0, "bold": false, "italic": false}
  ]
}
''';

/// Builds a controller whose Dio routes by path, plus the adapter so tests can
/// inspect the last request. [downloadService] is injected for download tests.
({EditController controller, _RoutingAdapter adapter}) _build({
  _Reply? Function(String method, String path)? route,
  DownloadService? downloadService,
}) {
  final adapter = _RoutingAdapter(
    route ??
        (method, path) {
          if (path.endsWith('/edit/open')) {
            return const _Reply(200, _openBodyWithText);
          }
          if (path.endsWith('/edit/apply')) return const _Reply(200, _applyOkBody);
          if (path.endsWith('/edit/ocr')) return const _Reply(200, _ocrOkBody);
          if (path.endsWith('/state')) {
            return const _Reply(200, _stateAfterOcrBody);
          }
          return null;
        },
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final api = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  final controller =
      EditController(api: api, downloadService: downloadService);
  return (controller: controller, adapter: adapter);
}

/// A DownloadService whose Save-As + streamed download are fakes.
DownloadService _fakeDownloadService(
  ApiClient api, {
  required FileSaveLocation? Function() onSaveLocation,
  Future<void> Function(Uri uri, String savePath)? onDownload,
}) {
  return DownloadService(
    api,
    saveLocationResolver: ({
      required String suggestedName,
      required List<XTypeGroup> acceptedTypeGroups,
    }) async =>
        onSaveLocation(),
    downloader: (
      Uri uri,
      String savePath, {
      CancelToken? cancelToken,
      ProgressCallback? onReceiveProgress,
    }) async {
      if (onDownload != null) await onDownload(uri, savePath);
    },
  );
}

void main() {
  group('in-place edit recording (Req 15.4)', () {
    test('setSpanText records, toggles, and clears a pending edit', () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

      final span = h.controller.spans.first;
      expect(h.controller.effectiveText(span), 'Hello');
      expect(h.controller.isSpanEdited('p1_s0'), isFalse);

      h.controller.setSpanText('p1_s0', 'Howdy');
      expect(h.controller.effectiveText(span), 'Howdy');
      expect(h.controller.isSpanEdited('p1_s0'), isTrue);
      expect(h.controller.pendingEditCount, 1);
      expect(h.controller.hasPendingEdits, isTrue);

      // Re-typing the original text "un-edits" the span.
      h.controller.setSpanText('p1_s0', 'Hello');
      expect(h.controller.isSpanEdited('p1_s0'), isFalse);
      expect(h.controller.pendingEditCount, 0);
    });

    test('setSpanText for an unknown span id is a no-op', () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

      h.controller.setSpanText('missing', 'x');
      expect(h.controller.pendingEditCount, 0);
    });

    test('buildOperations emits edit_text ops carrying span page/bbox/style',
        () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

      h.controller.setSpanText('p1_s1', 'Earth');
      final ops = h.controller.buildOperations();

      expect(ops, hasLength(1));
      final OperationModel op = ops.single;
      expect(op.type, 'edit_text');
      expect(op.page, 1);
      expect(op.bbox, const <double>[10.0, 60.0, 120.0, 80.0]);
      expect(op.text, 'Earth');
      expect(op.font, 'Times');
      expect(op.size, 14.0);
      expect(op.color, 0);
    });
  });

  group('apply (Req 15.5)', () {
    test('canApply requires text, pending edits, and not busy', () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

      expect(h.controller.canApply, isFalse); // no edits yet
      h.controller.setSpanText('p1_s0', 'Hi');
      expect(h.controller.canApply, isTrue);
    });

    test('apply posts to /edit/apply and makes the job downloadable',
        () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');
      h.controller.setSpanText('p1_s0', 'Hi');

      final ok = await h.controller.apply();

      expect(ok, isTrue);
      expect(h.adapter.lastRequest?.path, '/api/tools/edit/apply');
      // The job id and operations were sent in the JSON body.
      final body = jsonDecode(h.adapter.lastBody!) as Map<String, dynamic>;
      expect(body['job_id'], 'job-1');
      expect((body['operations'] as List<dynamic>), hasLength(1));
      expect(h.controller.applyResult?.editsApplied, 1);
      expect(h.controller.canDownload, isTrue);
      expect(h.controller.actionError, isNull);
    });

    test('apply surfaces the engine detail and keeps the document on error',
        () async {
      final h = _build(
        route: (method, path) {
          if (path.endsWith('/edit/open')) {
            return const _Reply(200, _openBodyWithText);
          }
          if (path.endsWith('/edit/apply')) {
            return const _Reply(500, '{"detail": "Couldn\'t apply those edits."}');
          }
          return null;
        },
      );
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');
      h.controller.setSpanText('p1_s0', 'Hi');

      final ok = await h.controller.apply();

      expect(ok, isFalse);
      expect(h.controller.actionError, "Couldn't apply those edits.");
      expect(h.controller.canDownload, isFalse);
      // The staged document is preserved so the user can retry.
      expect(h.controller.hasDocument, isTrue);
      expect(h.controller.status, EditStatus.ready);
    });
  });

  group('OCR (Req 15.6)', () {
    test('OCR DPI validation honors the engine 150-600 bounds', () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'scan.pdf');

      h.controller.ocrDpiText = '300';
      expect(h.controller.isOcrDpiValid, isTrue);
      h.controller.ocrDpiText = '149';
      expect(h.controller.isOcrDpiValid, isFalse);
      h.controller.ocrDpiText = '601';
      expect(h.controller.isOcrDpiValid, isFalse);
      h.controller.ocrDpiText = 'abc';
      expect(h.controller.isOcrDpiValid, isFalse);
    });

    test('runOcr posts to /edit/ocr, reopens the result, and is downloadable',
        () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'scan.pdf');

      h.controller.ocrLanguages = 'eng+hin';
      h.controller.ocrDpiText = '300';

      final ok = await h.controller.runOcr();

      expect(ok, isTrue);
      expect(h.controller.ocrResult?.pagesOcred, 3);
      expect(h.controller.ocrResult?.languages, 'eng+hin');
      // After OCR the searchable result is reopened as the new editable source.
      expect(h.controller.response?.jobId, 'ocr-9');
      expect(h.controller.hasText, isTrue);
      expect(h.controller.fileName, 'scan_ocr.pdf');
      expect(h.controller.canDownload, isTrue);
    });

    test('runOcr surfaces the engine detail on error', () async {
      final h = _build(
        route: (method, path) {
          if (path.endsWith('/edit/open')) {
            return const _Reply(200, _openBodyNoText);
          }
          if (path.endsWith('/edit/ocr')) {
            return const _Reply(500, '{"detail": "Couldn\'t OCR that PDF."}');
          }
          return null;
        },
      );
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'scan.pdf');

      final ok = await h.controller.runOcr();

      expect(ok, isFalse);
      expect(h.controller.actionError, "Couldn't OCR that PDF.");
      expect(h.controller.canDownload, isFalse);
    });
  });

  group('download (Req 15.7)', () {
    test('download targets the edit/download endpoint and saves', () async {
      Uri? requested;
      final adapter = _RoutingAdapter((method, path) {
        if (path.endsWith('/edit/open')) {
          return const _Reply(200, _openBodyWithText);
        }
        if (path.endsWith('/edit/apply')) return const _Reply(200, _applyOkBody);
        return null;
      });
      final api = ApiClient(
        Uri.parse('http://127.0.0.1:54321'),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final dl = _fakeDownloadService(
        api,
        onSaveLocation: () => const FileSaveLocation('/tmp/out.pdf'),
        onDownload: (uri, path) async => requested = uri,
      );
      final c = EditController(api: api, downloadService: dl);
      addTearDown(c.dispose);

      await c.open(fileBytes: const <int>[1], filename: 'a.pdf');
      c.setSpanText('p1_s0', 'Hi');
      await c.apply();

      final result = await c.download();

      expect(result, isNotNull);
      expect(result!.isSaved, isTrue);
      expect(result.path, '/tmp/out.pdf');
      expect(
        requested.toString(),
        'http://127.0.0.1:54321/api/tools/edit/download/job-1',
      );
    });

    test('download returns cancelled when the user dismisses Save-As',
        () async {
      final api = ApiClient(
        Uri.parse('http://127.0.0.1:54321'),
        dio: Dio()
          ..httpClientAdapter = _RoutingAdapter((method, path) {
            if (path.endsWith('/edit/open')) {
              return const _Reply(200, _openBodyWithText);
            }
            if (path.endsWith('/edit/apply')) {
              return const _Reply(200, _applyOkBody);
            }
            return null;
          }),
      );
      final dl = _fakeDownloadService(
        api,
        onSaveLocation: () => null, // user cancelled the dialog
      );
      final c = EditController(api: api, downloadService: dl);
      addTearDown(c.dispose);

      await c.open(fileBytes: const <int>[1], filename: 'a.pdf');
      c.setSpanText('p1_s0', 'Hi');
      await c.apply();

      final result = await c.download();
      expect(result, isNotNull);
      expect(result!.isCancelled, isTrue);
      expect(c.actionError, isNull);
    });

    test('download is a no-op (null) before anything is produced', () async {
      final h = _build();
      addTearDown(h.controller.dispose);
      await h.controller.open(fileBytes: const <int>[1], filename: 'a.pdf');

      expect(h.controller.canDownload, isFalse);
      final result = await h.controller.download();
      expect(result, isNull);
    });

    test('download surfaces a DownloadException message as actionError',
        () async {
      final api = ApiClient(
        Uri.parse('http://127.0.0.1:54321'),
        dio: Dio()
          ..httpClientAdapter = _RoutingAdapter((method, path) {
            if (path.endsWith('/edit/open')) {
              return const _Reply(200, _openBodyWithText);
            }
            if (path.endsWith('/edit/apply')) {
              return const _Reply(200, _applyOkBody);
            }
            return null;
          }),
      );
      final dl = _fakeDownloadService(
        api,
        onSaveLocation: () => const FileSaveLocation('/tmp/out.pdf'),
        onDownload: (uri, path) async =>
            throw Exception('Disk is full.'),
      );
      final c = EditController(api: api, downloadService: dl);
      addTearDown(c.dispose);

      await c.open(fileBytes: const <int>[1], filename: 'a.pdf');
      c.setSpanText('p1_s0', 'Hi');
      await c.apply();

      final result = await c.download();
      expect(result, isNull);
      // A disk/transport error surfaces through DownloadService as a readable
      // message that the controller records in actionError (Req 15.7 / 16.5).
      expect(c.actionError, contains('Disk is full.'));
    });
  });
}
