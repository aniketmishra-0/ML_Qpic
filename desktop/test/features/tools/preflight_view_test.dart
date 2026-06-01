// Widget tests for PreflightView — render the report + wire the engine
// (Task 18.3 — Requirement 14.2, with 14.1 endpoint wiring and 14.6 error
// surfacing as the panel presents them).
//
// These confirm the panel:
//   * runs the engine inspection against `POST /api/tools/preflight` (14.1),
//   * renders verdict, page_count, page_sizes, checks, fonts, images, and
//     page_details from the response (14.2),
//   * shows the one-click "Fix page sizes" affordance only when the report
//     reports mixed page sizes — the negative case here (14.3), and
//   * surfaces the engine `detail` in an inline error banner (14.6).
//
// A capturing fake Dio adapter records the last request, so no real network is
// used and the endpoint wiring is asserted directly (mirrors the Compress/Edit
// tool test patterns).
//
// NOTE (out of 18.3 scope): exercising the mixed-page-sizes Fix section
// (Req 14.3 positive / 14.4) currently trips a Flutter framework assertion
// because `_FixPageSizesSection` in preflight_view.dart wraps its
// RadioListTiles in a decorated Container with no intervening Material. That is
// a latent lib defect outside this test-only task's scope (14.2). It is
// reported separately; these tests deliberately use a uniform-size report so
// the in-scope rendering path is verified without hitting it.

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/tools/preflight/preflight_controller.dart';
import 'package:qpic_desktop/features/tools/preflight/preflight_view.dart';

/// A fake adapter that returns a fixed response and records the last request
/// (path, content-type), draining any multipart request stream.
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

({PreflightController controller, _CapturingAdapter adapter}) _build({
  required int statusCode,
  required String body,
}) {
  final adapter = _CapturingAdapter(statusCode: statusCode, body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  final controller = PreflightController(
    apiClient: apiClient,
    downloadService: DownloadService(
      apiClient,
      saveLocationResolver: ({
        required String suggestedName,
        required List<XTypeGroup> acceptedTypeGroups,
      }) async =>
          const FileSaveLocation('/chosen/normalized.pdf'),
      downloader: (uri, savePath,
          {CancelToken? cancelToken,
          ProgressCallback? onReceiveProgress}) async {},
    ),
  );
  return (controller: controller, adapter: adapter);
}

Widget _host(PreflightController controller) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(body: PreflightView(controller: controller)),
  );
}

/// A full, print-clean report (uniform page sizes) that still populates every
/// rendered section the requirement enumerates: verdict, page_count,
/// page_sizes, checks, fonts, images, and page_details (14.2).
const String _reportBody = '''
{
  "verdict": "warn",
  "page_count": 2,
  "page_sizes": ["A4"],
  "file_size": 204800,
  "is_encrypted": false,
  "has_text_layer": true,
  "checks": [
    {"id": "encryption", "title": "Not encrypted", "status": "ok", "detail": "No password protection."},
    {"id": "image_dpi", "title": "Low image DPI", "status": "warn", "detail": "An image is below 150 DPI."}
  ],
  "fonts": [
    {"name": "Helvetica", "type": "Type1", "embedded": true, "subset": false}
  ],
  "images": [
    {"page": 1, "width": 1200, "height": 1600, "dpi": 150.0, "colorspace": "DeviceRGB", "bpc": 8}
  ],
  "metadata": {"Title": "Sample"},
  "distinct_page_sizes": ["A4"],
  "mixed_page_sizes": false,
  "page_details": [
    {"page": 1, "w_mm": 210.0, "h_mm": 297.0, "w_pt": 595.0, "h_pt": 842.0, "w_px": 1240, "h_px": 1754, "format": "A4", "orientation": "Portrait"},
    {"page": 2, "w_mm": 210.0, "h_mm": 297.0, "w_pt": 595.0, "h_pt": 842.0, "w_px": 1240, "h_px": 1754, "format": "A4", "orientation": "Portrait"}
  ]
}
''';

void main() {
  testWidgets('idle state shows the title and picker, no result yet',
      (tester) async {
    final h = _build(statusCode: 200, body: _reportBody);
    addTearDown(h.controller.dispose);

    await tester.pumpWidget(_host(h.controller));

    expect(find.byKey(const ValueKey('preflight-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-pick-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-verdict')), findsNothing);

    // Submit is disabled until a PDF is loaded.
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('preflight-submit')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
      'renders verdict/page_count/page_sizes/checks/fonts/images/page_details '
      'and wires POST /api/tools/preflight (14.1, 14.2)', (tester) async {
    final h = _build(statusCode: 200, body: _reportBody);
    addTearDown(h.controller.dispose);

    await tester.pumpWidget(_host(h.controller));

    h.controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');
    await tester.runAsync(() => h.controller.runPreflight());
    await tester.pump();

    // Endpoint wiring (14.1): the inspection POSTs to the engine preflight
    // route with the PDF as a multipart `file`.
    expect(h.adapter.lastRequest?.method, 'POST');
    expect(h.adapter.lastRequest?.path, '/api/tools/preflight');
    expect(h.adapter.lastContentType, contains('multipart/form-data'));

    // Every report section enumerated by Req 14.2 is rendered.
    expect(find.byKey(const ValueKey('preflight-verdict')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-page-count')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-page-sizes')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-checks')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-fonts')), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-images')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('preflight-page-details')), findsOneWidget);

    // The bound values come straight from the engine response.
    expect(find.text('WARN'), findsOneWidget); // verdict (upper-cased)
    expect(find.text('2'), findsOneWidget); // page_count
    expect(find.text('A4'), findsWidgets); // page_sizes joined
    expect(find.text('Not encrypted'), findsOneWidget); // a check title
    expect(find.text('Helvetica'), findsOneWidget); // a font name
  });

  testWidgets('no Fix affordance when the report has uniform page sizes (14.3)',
      (tester) async {
    final h = _build(statusCode: 200, body: _reportBody);
    addTearDown(h.controller.dispose);

    await tester.pumpWidget(_host(h.controller));
    h.controller.setFile(bytes: const <int>[1], filename: 'in.pdf');
    await tester.runAsync(() => h.controller.runPreflight());
    await tester.pump();

    expect(h.controller.result?.mixedPageSizes, isFalse);
    expect(find.byKey(const ValueKey('preflight-mixed-warning')), findsNothing);
    expect(find.byKey(const ValueKey('preflight-fix-submit')), findsNothing);
  });

  testWidgets('surfaces the engine error detail in a banner (14.6)',
      (tester) async {
    final h = _build(
      statusCode: 400,
      body: '{"detail": "That file is not a valid PDF."}',
    );
    addTearDown(h.controller.dispose);

    await tester.pumpWidget(_host(h.controller));

    expect(find.byKey(const ValueKey('preflight-error')), findsNothing);

    h.controller.setFile(bytes: const <int>[1], filename: 'x.pdf');
    await tester.runAsync(() => h.controller.runPreflight());
    await tester.pump();

    expect(find.byKey(const ValueKey('preflight-error')), findsOneWidget);
    expect(find.text('That file is not a valid PDF.'), findsOneWidget);
    expect(find.byKey(const ValueKey('preflight-verdict')), findsNothing);
  });
}
