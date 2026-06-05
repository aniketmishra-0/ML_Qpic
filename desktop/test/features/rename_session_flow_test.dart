// Unit tests for the Rename Batch PDF-to-images + streamed session flow
// (Requirements 12.3, 12.4, 12.5, 12.6) — task 15.2.
//
// These verify the controller drives the engine exactly as Requirement 12
// demands, with ZERO engine logic in Dart beyond the documented token
// expansion:
//   * adding a PDF calls `POST /api/rename/pdf-to-images` and turns each
//     returned page into a renamable item (12.3),
//   * renaming runs the session flow create → files (chunked) → finalize →
//     download → delete, sending pattern/start/padding/names/output_format/
//     jpg_quality on finalize (12.4) and releasing the session afterwards
//     (12.5),
//   * an engine error surfaces the `{"detail": ...}` message verbatim (12.6).
//
// The engine is faked with a routing Dio HttpClientAdapter (no network); the
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
import 'package:qpic_desktop/features/rename/rename_controller.dart';

/// One recorded request: method, path, and the multipart fields/files it
/// carried (decoded from the streamed body when present).
class _Recorded {
  _Recorded(this.method, this.path, this.fields, this.fileFields);

  final String method;
  final String path;

  /// Repeated form fields, e.g. {'names': ['["Q1"]'], 'pattern': ['#']}.
  final Map<String, List<String>> fields;

  /// Multipart file part names in order, e.g. ['files', 'files', 'file'].
  final List<String> fileFields;
}

/// A routing adapter that answers each rename endpoint with a canned JSON body
/// and records every request (including its multipart parts).
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter({this.failOn, this.failStatus = 400, this.failDetail = ''});

  /// When set, any request whose path ends with this fragment fails with
  /// [failStatus] + a `{"detail": failDetail}` body.
  final String? failOn;
  final int failStatus;
  final String failDetail;

  final List<_Recorded> requests = <_Recorded>[];

  int _filesCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = await _drain(requestStream);
    requests.add(_parse(options, body));

    final path = options.path;
    if (failOn != null && path.endsWith(failOn!)) {
      return _json(failStatus, jsonEncode(<String, dynamic>{'detail': failDetail}));
    }

    if (path.endsWith('/rename/pdf-to-session')) {
      return _json(
        200,
        jsonEncode(<String, dynamic>{
          'job_id': 'job-pdf-1',
          'count': 2,
          'pages': <Map<String, dynamic>>[
            {
              'name': 'doc_p1.jpg',
              'page_url': '/api/rename/pdf-page/job-pdf-1/doc_p1.jpg',
              'width': 100,
              'height': 200,
              'size': 3,
            },
            {
              'name': 'doc_p2.jpg',
              'page_url': '/api/rename/pdf-page/job-pdf-1/doc_p2.jpg',
              'width': 120,
              'height': 220,
              'size': 4,
            },
          ],
        }),
      );
    }
    if (path.contains('/rename/pdf-page/')) {
      if (path.endsWith('doc_p1.jpg')) {
        return _bytes(200, <int>[1, 2, 3]);
      }
      if (path.endsWith('doc_p2.jpg')) {
        return _bytes(200, <int>[4, 5, 6, 7]);
      }
    }
    if (path.endsWith('/rename/session')) {
      return _json(200, jsonEncode(<String, dynamic>{'session_id': 'sess-1'}));
    }
    if (path.endsWith('/files')) {
      _filesCalls += 1;
      // Echo a plausible running total per chunk.
      return _json(
        200,
        jsonEncode(<String, dynamic>{
          'session_id': 'sess-1',
          'received': 1,
          'total': _filesCalls,
        }),
      );
    }
    if (path.endsWith('/finalize')) {
      final isPdf = path.contains('/pdf-session/');
      return _json(
        200,
        jsonEncode(<String, dynamic>{
          'session_id': isPdf ? 'job-pdf-1' : 'sess-1',
          'count': 3,
          'download_url': isPdf
              ? '/api/rename/session/job-pdf-1/download'
              : '/api/rename/session/sess-1/download',
        }),
      );
    }
    if (options.method == 'DELETE') {
      return _json(200, jsonEncode(<String, dynamic>{'ok': true}));
    }
    return _json(404, jsonEncode(<String, dynamic>{'detail': 'unexpected'}));
  }

  @override
  void close({bool force = false}) {}

  static Future<List<int>> _drain(Stream<Uint8List>? stream) async {
    if (stream == null) return const <int>[];
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
    }
    return out;
  }

  static ResponseBody _json(int status, String body) {
    return ResponseBody.fromString(
      body,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  static ResponseBody _bytes(int status, List<int> bytes) {
    return ResponseBody.fromBytes(
      Uint8List.fromList(bytes),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['image/jpeg'],
      },
    );
  }

  /// Parses a multipart body into its repeated fields + file-part names by
  /// scanning the boundary parts' Content-Disposition headers.
  static _Recorded _parse(RequestOptions options, List<int> body) {
    final fields = <String, List<String>>{};
    final fileFields = <String>[];
    final contentType = options.contentType ?? '';
    if (contentType.contains('multipart/form-data') && body.isNotEmpty) {
      // Latin-1 keeps byte alignment for the textual headers we scan.
      final text = String.fromCharCodes(body);
      final dispositions = RegExp(
        r'content-disposition: form-data; name="([^"]*)"(; filename="([^"]*)")?',
        caseSensitive: false,
      );
      for (final m in dispositions.allMatches(text)) {
        final name = m.group(1) ?? '';
        final isFile = m.group(3) != null;
        if (isFile) {
          fileFields.add(name);
        } else {
          // The value sits after a blank line following the header.
          final after = text.substring(m.end);
          final valStart = after.indexOf('\r\n\r\n');
          var value = '';
          if (valStart != -1) {
            final rest = after.substring(valStart + 4);
            final end = rest.indexOf('\r\n');
            value = end == -1 ? rest : rest.substring(0, end);
          }
          (fields[name] ??= <String>[]).add(value);
        }
      }
    }
    return _Recorded(options.method, options.path, fields, fileFields);
  }
}

/// Builds a controller + recording engine. The DownloadService seams capture
/// the streamed URL/path without touching a real dialog or disk.
class _Harness {
  _Harness({String? failOn, int failStatus = 400, String failDetail = ''}) {
    adapter = _RoutingAdapter(
      failOn: failOn,
      failStatus: failStatus,
      failDetail: failDetail,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
    downloadService = DownloadService(
      apiClient,
      saveLocationResolver: ({
        required String suggestedName,
        required List<XTypeGroup> acceptedTypeGroups,
      }) async {
        seenSuggestedName = suggestedName;
        return saveLocation;
      },
      downloader: (uri, savePath,
          {CancelToken? cancelToken, ProgressCallback? onReceiveProgress}) async {
        streamedUri = uri;
        streamedPath = savePath;
      },
    );
    controller = RenameController()
      ..bindEngine(apiClient: apiClient, downloadService: downloadService);
  }

  late final _RoutingAdapter adapter;
  late final ApiClient apiClient;
  late final DownloadService downloadService;
  late final RenameController controller;

  FileSaveLocation? saveLocation = const FileSaveLocation('/chosen/renamed_images.zip');
  String? seenSuggestedName;
  Uri? streamedUri;
  String? streamedPath;

  List<_Recorded> get requests => adapter.requests;
}

void main() {
  group('addPdfBytes — PDF to images (Req 12.3)', () {
    test('calls /api/rename/pdf-to-session and adds one item per page', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);

      final ok = await h.controller.addPdfBytes(
        bytes: const <int>[9, 9, 9],
        filename: 'doc.pdf',
      );

      expect(ok, isTrue);
      // The PDF endpoint was hit with a multipart `file` part.
      final req = h.requests.singleWhere(
        (r) => r.path.endsWith('/rename/pdf-to-session'),
      );
      expect(req.method, 'POST');
      expect(req.fileFields, <String>['file']);

      // Two pages → two items, carrying the engine names + dimensions.
      expect(h.controller.itemCount, 2);
      expect(h.controller.items[0].name, 'doc_p1.jpg');
      expect(h.controller.items[0].fromPdf, isTrue);
      expect(h.controller.items[0].width, 100);
      expect(h.controller.items[1].name, 'doc_p2.jpg');

      // Verify that background downloading was skipped (pure PDF session).
      expect(h.controller.items[0].bytesForUpload(), isEmpty);
      expect(h.controller.items[1].bytesForUpload(), isEmpty);
    });

    test('rename on a pure PDF session runs direct finalize on the server (zero upload)', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      
      // Load PDF pages
      await h.controller.addPdfBytes(
        bytes: const <int>[9, 9, 9],
        filename: 'doc.pdf',
      );
      
      h.controller
        ..pattern = 'Q#'
        ..start = 5
        ..padding = 3
        ..downloadExcel = false
        ..outputFormat = RenameOutputFormat.png;

      final result = await h.controller.rename();

      expect(result, isNotNull);
      expect(result!.isSaved, isTrue);

      // Verify that the chunked upload endpoints were completely bypassed!
      // The requests should only be: POST /pdf-to-session, POST /pdf-session/.../finalize, and DELETE /pdf-session/...
      final paths = h.requests.map((r) => '${r.method} ${r.path}').toList();
      expect(paths.any((p) => p.contains('/files')), isFalse);
      expect(paths.any((p) => p.contains('/session') && !p.contains('/pdf-session')), isFalse);

      expect(paths, contains('POST /api/rename/pdf-session/job-pdf-1/finalize'));
      expect(paths, contains('DELETE /api/rename/pdf-session/job-pdf-1'));
    });

    test('surfaces the engine detail on a PDF conversion error (Req 12.6)', () async {
      final h = _Harness(
        failOn: '/rename/pdf-to-session',
        failStatus: 400,
        failDetail: 'Not a PDF: doc.pdf. Upload a .pdf file.',
      );
      addTearDown(h.controller.dispose);

      final ok = await h.controller.addPdfBytes(
        bytes: const <int>[1],
        filename: 'doc.pdf',
      );

      expect(ok, isFalse);
      expect(h.controller.itemCount, 0);
      expect(h.controller.errorText, 'Not a PDF: doc.pdf. Upload a .pdf file.');
    });

    test('does nothing when no engine is bound', () async {
      final c = RenameController();
      addTearDown(c.dispose);

      final ok = await c.addPdfBytes(bytes: const <int>[1], filename: 'a.pdf');

      expect(ok, isFalse);
      expect(c.itemCount, 0);
    });
  });

  group('rename — streamed session flow (Req 12.4, 12.5)', () {
    test('runs create → files → finalize → download → delete in order', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      h.controller
        ..pattern = 'Q#'
        ..start = 5
        ..padding = 3
        ..outputFormat = RenameOutputFormat.png
        ..addItems(<RenameItem>[
          RenameItem(name: 'a.png', sizeBytes: 1, fileBytes: const <int>[1]),
          RenameItem(name: 'b.png', sizeBytes: 1, fileBytes: const <int>[2]),
        ]);

      final result = await h.controller.rename();

      expect(result, isNotNull);
      expect(result!.isSaved, isTrue);

      // Endpoint ordering: session → files → finalize → delete (download is
      // the injected streamer, recorded separately).
      final paths = h.requests.map((r) => '${r.method} ${r.path}').toList();
      expect(paths[0], 'POST /api/rename/session');
      expect(paths[1], 'POST /api/rename/session/sess-1/files');
      expect(paths[2], 'POST /api/rename/session/sess-1/finalize');
      expect(paths.last, 'DELETE /api/rename/session/sess-1');

      // The ZIP was streamed to the chosen path from the finalize download_url.
      expect(h.seenSuggestedName, 'renamed_images.zip');
      expect(h.streamedPath, '/chosen/renamed_images.zip');
      expect(
        h.streamedUri.toString(),
        'http://127.0.0.1:54321/api/rename/session/sess-1/download',
      );
    });

    test('finalize carries pattern/start/padding/names/output_format/jpg_quality',
        () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      h.controller
        ..pattern = 'Q#'
        ..start = 5
        ..padding = 3
        ..jpgQuality = 77
        ..outputFormat = RenameOutputFormat.jpg
        ..addItems(<RenameItem>[
          RenameItem(name: 'a.png', sizeBytes: 1, fileBytes: const <int>[1]),
          RenameItem(name: 'b.png', sizeBytes: 1, fileBytes: const <int>[2]),
        ]);

      await h.controller.rename();

      final finalize = h.requests.singleWhere((r) => r.path.endsWith('/finalize'));
      expect(finalize.fields['pattern'], <String>['Q#']);
      expect(finalize.fields['start'], <String>['5']);
      expect(finalize.fields['padding'], <String>['3']);
      expect(finalize.fields['output_format'], <String>['jpg']);
      expect(finalize.fields['jpg_quality'], <String>['77']);
      // names is a single JSON-array string of the planned stems, in order.
      // With start=5 and padding=3, the `#` token expands to a zero-padded
      // running number, so the stems are Q005 / Q006.
      final names = finalize.fields['names']!.single;
      expect(jsonDecode(names), <String>['Q005', 'Q006']);
    });

    test('uploads files in chunks of renameUploadChunk', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      const total = RenameController.renameUploadChunk + 5;
      h.controller.addItems(<RenameItem>[
        for (var i = 0; i < total; i++)
          RenameItem(name: 'f$i.png', sizeBytes: 1, fileBytes: const <int>[1]),
      ]);

      await h.controller.rename();

      final fileReqs =
          h.requests.where((r) => r.path.endsWith('/files')).toList();
      expect(fileReqs.length, 2); // 200 + 5 → two chunks
      expect(fileReqs[0].fileFields.length, RenameController.renameUploadChunk);
      expect(fileReqs[1].fileFields.length, 5);
      // Every uploaded part uses the `files` multipart field name.
      expect(fileReqs[0].fileFields.toSet(), <String>{'files'});
    });

    test('deletes the session even when the user cancels the Save-As dialog',
        () async {
      final h = _Harness()..saveLocation = null; // user cancels
      addTearDown(h.controller.dispose);
      h.controller.addItems(<RenameItem>[
        RenameItem(name: 'a.png', sizeBytes: 1, fileBytes: const <int>[1]),
      ]);

      final result = await h.controller.rename();

      expect(result, isNotNull);
      expect(result!.isCancelled, isTrue);
      expect(h.streamedUri, isNull); // nothing streamed
      // Session is still released (Req 12.5).
      expect(
        h.requests.any((r) => r.method == 'DELETE' && r.path.endsWith('/sess-1')),
        isTrue,
      );
    });

    test('does nothing when there are no items', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);

      final result = await h.controller.rename();

      expect(result, isNull);
      expect(h.requests, isEmpty);
    });
  });

  group('rename — error handling (Req 12.6)', () {
    test('surfaces the engine detail when finalize fails', () async {
      final h = _Harness(
        failOn: '/finalize',
        failStatus: 400,
        failDetail: 'Name count does not match the number of staged files.',
      );
      addTearDown(h.controller.dispose);
      h.controller.addItems(<RenameItem>[
        RenameItem(name: 'a.png', sizeBytes: 1, fileBytes: const <int>[1]),
      ]);

      final result = await h.controller.rename();

      expect(result, isNull);
      expect(
        h.controller.errorText,
        'Name count does not match the number of staged files.',
      );
      // The session is still cleaned up after a finalize failure (Req 12.5).
      expect(
        h.requests.any((r) => r.method == 'DELETE' && r.path.endsWith('/sess-1')),
        isTrue,
      );
    });

    test('surfaces the engine detail when a files chunk fails', () async {
      final h = _Harness(
        failOn: '/files',
        failStatus: 400,
        failDetail: 'Unsupported file type: a.txt. Images only.',
      );
      addTearDown(h.controller.dispose);
      h.controller.addItems(<RenameItem>[
        RenameItem(name: 'a.txt', sizeBytes: 1, fileBytes: const <int>[1]),
      ]);

      final result = await h.controller.rename();

      expect(result, isNull);
      expect(
        h.controller.errorText,
        'Unsupported file type: a.txt. Images only.',
      );
    });
  });

  group('engine binding', () {
    test('engineReady reflects bind/unbind', () {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      expect(h.controller.engineReady, isTrue);

      h.controller.unbindEngine();
      expect(h.controller.engineReady, isFalse);
      expect(h.controller.apiClient, isNull);
    });
  });
}
