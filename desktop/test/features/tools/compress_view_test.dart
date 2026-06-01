// Render smoke tests for CompressView (Requirement 13).
//
// These confirm the panel renders its controls with stable keys and that it
// reflects controller state: the four level cards (13.1), the target-size
// toggle + field (13.1), the engine result block showing original/compressed/
// ratio (13.3) with a Download action (13.4), and the engine-error banner
// (13.5). Endpoint wiring is exercised by the controller test.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/tools/compress/compress_controller.dart';
import 'package:qpic_desktop/features/tools/compress/compress_view.dart';

/// A fake adapter that returns a fixed JSON body, draining any request stream.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

CompressController _controller({HttpClientAdapter? adapter}) {
  final dio = Dio();
  if (adapter != null) dio.httpClientAdapter = adapter;
  final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  return CompressController(
    apiClient: apiClient,
    downloadService: DownloadService(
      apiClient,
      saveLocationResolver: ({
        required String suggestedName,
        required List<XTypeGroup> acceptedTypeGroups,
      }) async =>
          null,
      downloader: (uri, savePath,
          {CancelToken? cancelToken,
          ProgressCallback? onReceiveProgress}) async {},
    ),
  );
}

Widget _host(CompressController controller) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(body: CompressView(controller: controller)),
  );
}

void main() {
  testWidgets('renders the four compression level cards', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('compress-level-light')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('compress-level-balanced')), findsOneWidget);
    expect(find.byKey(const ValueKey('compress-level-strong')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('compress-level-extreme')), findsOneWidget);
  });

  testWidgets('target-size field appears only when the toggle is on',
      (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('compress-target-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('compress-target-mb')), findsNothing);

    controller.useTarget = true;
    await tester.pump();
    expect(find.byKey(const ValueKey('compress-target-mb')), findsOneWidget);
  });

  testWidgets('Compress button is disabled until a file is loaded',
      (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('compress-submit')),
    );
    expect(button.onPressed, isNull);

    controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');
    await tester.pump();

    final enabled = tester.widget<FilledButton>(
      find.byKey(const ValueKey('compress-submit')),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('renders the result fields and download action', (tester) async {
    final body = jsonEncode(<String, dynamic>{
      'job_id': 'j',
      'original_size': 1048576,
      'compressed_size': 524288,
      'ratio': 0.5,
      'level': 'balanced',
      'target_met': null,
      'note': '',
      'download_url': '/api/tools/compress/download/j',
    });
    final controller = _controller(
      adapter: _StubAdapter(statusCode: 200, body: body),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');
    await tester.runAsync(() => controller.compress());
    await tester.pump();

    expect(find.byKey(const ValueKey('compress-result-ratio')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('compress-result-original')), findsOneWidget);
    expect(find.byKey(const ValueKey('compress-result-compressed')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('compress-result-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('compress-download')), findsOneWidget);

    // 50% smaller; before 1.0 MB, after 512 KB (web-parity formatting).
    expect(find.text('50% smaller'), findsOneWidget);
    expect(find.text('1.0 MB'), findsOneWidget);
    expect(find.text('512 KB'), findsOneWidget);
  });

  testWidgets('shows the engine error banner when errorText is set',
      (tester) async {
    final body = jsonEncode(<String, dynamic>{
      'detail': 'target_mb must be greater than 0.',
    });
    final controller = _controller(
      adapter: _StubAdapter(statusCode: 400, body: body),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('compress-error')), findsNothing);

    controller.setFile(bytes: const <int>[1, 2, 3], filename: 'in.pdf');
    await tester.runAsync(() => controller.compress());
    await tester.pump();

    expect(find.byKey(const ValueKey('compress-error')), findsOneWidget);
    expect(find.text('target_mb must be greater than 0.'), findsOneWidget);
  });
}
