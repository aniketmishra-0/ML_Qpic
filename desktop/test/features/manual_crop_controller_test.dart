// Unit tests for the ManualCropController open flow + independent output fields
// (Task 13.1 — Requirements 7.1, 7.2, 7.3, 7.6).
//
// These verify the controller behaves exactly as the task demands:
//   * open() POSTs /api/prepare-manual with the `dpi` query + multipart file
//     and opens the Review Canvas with an EMPTY item list, every page preview
//     loaded from its `preview_url` (7.1, 7.2),
//   * the output fields (prefix/start/format/quality) are held independently of
//     the Auto Crop tool — changing one tool's field never alters the other's
//     (7.3),
//   * a prepare-manual error (e.g. a non-PDF rejected with HTTP 400) does NOT
//     open the canvas and surfaces the engine `detail` verbatim (7.6).
//
// The engine is faked with a capturing Dio HttpClientAdapter (no network).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart';
import 'package:qpic_desktop/features/manual_crop/manual_crop_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';

/// A fake adapter that returns a fixed response and records the last request.
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

/// Builds a controller whose ApiClient returns [body] with [statusCode].
ManualCropController _controllerFor({
  required int statusCode,
  required String body,
  _CapturingAdapter? Function(_CapturingAdapter adapter)? capture,
}) {
  final adapter = _CapturingAdapter(statusCode: statusCode, body: body);
  capture?.call(adapter);
  final dio = Dio()..httpClientAdapter = adapter;
  final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  return ManualCropController(apiClient: apiClient);
}

/// A prepare-manual response: pages with preview URLs, empty items/notes.
String _prepareManualBody({int pages = 3}) {
  return jsonEncode(<String, dynamic>{
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

void main() {
  group('open() → prepare-manual → Review Canvas (Req 7.1, 7.2)', () {
    test('POSTs /api/prepare-manual with the dpi query + multipart file',
        () async {
      late _CapturingAdapter adapter;
      final c = _controllerFor(
        statusCode: 200,
        body: _prepareManualBody(pages: 3),
        capture: (a) => adapter = a,
      );
      addTearDown(c.dispose);

      c
        ..dpi = 300
        ..setFile(bytes: const <int>[1, 2, 3], filename: 'paper.pdf');

      final ok = await c.open();

      expect(ok, isTrue);
      final req = adapter.lastRequest;
      expect(req?.path, '/api/prepare-manual');
      expect(req?.method, 'POST');
      expect(req?.queryParameters['dpi'], 300);
      expect(adapter.lastContentType, contains('multipart/form-data'));
    });

    test('opens the canvas with an EMPTY item list and all page previews',
        () async {
      final c = _controllerFor(
        statusCode: 200,
        body: _prepareManualBody(pages: 3),
      );
      addTearDown(c.dispose);

      c.setFile(bytes: const <int>[1], filename: 'paper.pdf');
      await c.open();

      expect(c.canvasOpen, isTrue);
      expect(c.review.source, ReviewSource.manualCrop);
      expect(c.review.items, isEmpty, reason: 'manual crop starts empty');
      expect(c.review.notes, isEmpty);
      expect(c.review.answerKeyCount, isNull);
      // Every page preview is loaded from its engine-provided preview_url.
      expect(c.review.pages.length, 3);
      expect(
        c.review.pages.map((p) => p.previewUrl).toList(),
        <String>[
          '/api/analyze/manual-job-1/page/1',
          '/api/analyze/manual-job-1/page/2',
          '/api/analyze/manual-job-1/page/3',
        ],
      );
      expect(c.review.currentPageIndex, 0);
    });

    test('open() is a no-op without a bound engine or a file', () async {
      // No engine bound.
      final noEngine = ManualCropController();
      addTearDown(noEngine.dispose);
      noEngine.setFile(bytes: const <int>[1], filename: 'p.pdf');
      expect(await noEngine.open(), isFalse);
      expect(noEngine.canvasOpen, isFalse);

      // Engine bound but no file selected.
      final noFile = _controllerFor(
        statusCode: 200,
        body: _prepareManualBody(),
      );
      addTearDown(noFile.dispose);
      expect(await noFile.open(), isFalse);
      expect(noFile.canvasOpen, isFalse);
    });
  });

  group('prepare-manual error keeps the canvas closed (Req 7.6)', () {
    test('a non-PDF rejected with HTTP 400 surfaces detail, no canvas',
        () async {
      late _CapturingAdapter adapter;
      final c = _controllerFor(
        statusCode: 400,
        body: jsonEncode(<String, dynamic>{
          'detail': 'Please upload a PDF file.',
        }),
        capture: (a) => adapter = a,
      );
      addTearDown(c.dispose);

      c.setFile(bytes: const <int>[0, 1], filename: 'photo.png');
      final ok = await c.open();

      expect(ok, isFalse);
      expect(c.canvasOpen, isFalse, reason: 'canvas must not open on error');
      expect(c.errorText, 'Please upload a PDF file.');
      // A request WAS attempted (the engine performs the 400 rejection).
      expect(adapter.requestCount, 1);
      expect(c.review.pages, isEmpty);
    });
  });

  group('independent output fields (Req 7.3)', () {
    test('changing Manual Crop fields does not alter Auto Crop fields', () {
      final manual = ManualCropController();
      addTearDown(manual.dispose);
      final auto = AutoCropController();
      addTearDown(auto.dispose);

      // Mutate the manual tool's output config.
      manual
        ..questionPrefix = 'MQ'
        ..solutionPrefix = 'MS'
        ..startNumber = 42
        ..imageFormat = CropImageFormat.jpg
        ..jpgQuality = 55;

      // Auto Crop's fields are untouched (independent instance, Req 7.3).
      expect(auto.questionPrefix, 'Q');
      expect(auto.solutionPrefix, 'S');
      expect(auto.startNumber, AutoCropBounds.startNumberDefault);
      expect(auto.imageFormat, CropImageFormat.png);
      expect(auto.jpgQuality, AutoCropBounds.jpgQualityDefault);

      // And the manual tool kept its own values.
      expect(manual.questionPrefix, 'MQ');
      expect(manual.solutionPrefix, 'MS');
      expect(manual.startNumber, 42);
      expect(manual.imageFormat, CropImageFormat.jpg);
      expect(manual.jpgQuality, 55);
    });

    test('changing Auto Crop fields does not alter Manual Crop fields', () {
      final manual = ManualCropController();
      addTearDown(manual.dispose);
      final auto = AutoCropController();
      addTearDown(auto.dispose);

      auto
        ..questionPrefix = 'AQ'
        ..startNumber = 7
        ..imageFormat = CropImageFormat.jpg
        ..jpgQuality = 33;

      expect(manual.questionPrefix, 'Q');
      expect(manual.startNumber, AutoCropBounds.startNumberDefault);
      expect(manual.imageFormat, CropImageFormat.png);
      expect(manual.jpgQuality, AutoCropBounds.jpgQualityDefault);
    });

    test('output fields clamp/truncate to engine bounds', () {
      final c = ManualCropController();
      addTearDown(c.dispose);

      c
        ..questionPrefix = 'TooLongPrefixValue' // > 10 chars
        ..startNumber = 999999 // > max
        ..jpgQuality = 500 // > max
        ..dpi = 9000; // > max

      expect(c.questionPrefix.length, AutoCropBounds.prefixMaxLength);
      expect(c.startNumber, AutoCropBounds.startNumberMax);
      expect(c.jpgQuality, AutoCropBounds.jpgQualityMax);
      expect(c.dpi, AutoCropBounds.dpiMax);
    });
  });

  group('closeCanvas returns to the open form', () {
    test('clears the review session and flips canvasOpen false', () async {
      final c = _controllerFor(
        statusCode: 200,
        body: _prepareManualBody(pages: 2),
      );
      addTearDown(c.dispose);

      c.setFile(bytes: const <int>[1], filename: 'paper.pdf');
      await c.open();
      expect(c.canvasOpen, isTrue);

      c.closeCanvas();
      expect(c.canvasOpen, isFalse);
      expect(c.review.pages, isEmpty);
    });
  });

  group('engine bind/unbind', () {
    test('engineReady tracks bind/unbind', () {
      final apiClient = ApiClient(Uri.parse('http://127.0.0.1:1'));
      final c = ManualCropController();
      addTearDown(c.dispose);

      expect(c.engineReady, isFalse);
      c.bindEngine(apiClient: apiClient);
      expect(c.engineReady, isTrue);
      c.unbindEngine();
      expect(c.engineReady, isFalse);
    });
  });

  group('bilingual mode prefixes and reset preservation', () {
    test('setting bilingualModeActive to true defaults prefixes to EQ and ES', () {
      final c = ManualCropController();
      addTearDown(c.dispose);

      expect(c.questionPrefix, 'Q');
      expect(c.solutionPrefix, 'S');

      c.bilingualModeActive = true;
      expect(c.questionPrefix, 'EQ');
      expect(c.solutionPrefix, 'ES');
    });

    test('reset preserves bilingualModeActive and defaults prefixes to EQ and ES when active', () {
      final c = ManualCropController();
      addTearDown(c.dispose);

      c.bilingualModeActive = true;
      c.questionPrefix = 'CustomQ';
      c.solutionPrefix = 'CustomS';

      c.reset();
      expect(c.bilingualModeActive, isTrue);
      expect(c.questionPrefix, 'EQ');
      expect(c.solutionPrefix, 'ES');
    });
  });
}
