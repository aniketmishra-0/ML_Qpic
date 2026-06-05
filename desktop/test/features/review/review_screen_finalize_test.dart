// Widget tests for the ReviewScreen finalize + download UI
// (Task 12.6 — Requirements 6.6, 11.1, 11.2, 11.3, 11.4, 11.5).
//
// Task 12.5 wired the analyze→review ENTRY; task 12.6 adds the finalize and
// download-from-review affordances ON the screen: the Finalize button drives
// `onFinalize`, and once a finalize succeeds a download bar offers the Combined
// archive plus the Questions-only / Solutions-only archives the engine reported
// (Req 11.1–11.3). These verify the SCREEN wiring (the controller-level
// orchestration is covered by review_finalize_download_test.dart):
//   * the download bar is hidden until a finalize succeeds,
//   * tapping Finalize (wired to controller.finalize) reveals the bar,
//   * Combined is always offered; Questions/Solutions appear only when their
//     URL is reported,
//   * tapping a download button streams through GET /api/crop/download/{job_id}
//     with the right kind + prefixes (Req 11.4) and confirms the save,
//   * an engine error surfaces the detail banner and no download bar.
//
// The engine is faked with a capturing Dio adapter (no network); the
// DownloadService runs through its injectable save/stream seams (no dialog or
// disk). Preview URLs are empty so the canvas painter fetches no image.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/features/review/review_screen.dart';
import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';

/// A fake adapter returning a fixed response for /api/finalize.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.statusCode, required this.body});

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

class _Harness {
  _Harness({required int statusCode, required String body}) {
    final adapter = _CapturingAdapter(statusCode: statusCode, body: body);
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
      },
    );
    controller = ReviewController(
      apiClient: apiClient,
      downloadService: downloadService,
    );
  }

  late final ApiClient apiClient;
  late final DownloadService downloadService;
  late final ReviewController controller;

  final List<String> seenSuggestedNames = <String>[];
  final List<Uri> streamedUris = <Uri>[];
}

PageInfo _page(int n) => PageInfo(
      page: n,
      widthPt: 600,
      heightPt: 800,
      previewUrl: '', // empty → no network fetch in the test
    );

AnalyzedItem _item(String qNum) => AnalyzedItem(
      qNum: qNum,
      source: 'auto',
      segments: const <QuestionSegment>[
        QuestionSegment(
          page: 1,
          xStartPct: 10,
          xEndPct: 50,
          yStartPct: 10,
          yEndPct: 50,
        ),
      ],
    );

AnalyzeResponse _analyze({
  int answerKeyCount = 0,
  List<AnalyzedItem>? items,
}) =>
    AnalyzeResponse(
      jobId: 'fin-job',
      totalPages: 1,
      methodUsed: 'text',
      pages: <PageInfo>[_page(1)],
      items: items ?? <AnalyzedItem>[_item('1')],
      notes: const <ReviewNote>[],
      needsReview: false,
      answerKeyCount: answerKeyCount,
    );

String _cropBody({
  String? questionsUrl,
  String? solutionsUrl,
  int questionsCount = 0,
  int solutionsCount = 0,
}) {
  return jsonEncode(<String, dynamic>{
    'job_id': 'fin-job',
    'total_questions': questionsCount + solutionsCount,
    'stitched_questions': 0,
    'method_used': 'text',
    'download_url': '/api/crop/download/fin-job',
    'questions_download_url': questionsUrl,
    'solutions_download_url': solutionsUrl,
    'questions_count': questionsCount,
    'solutions_count': solutionsCount,
    'answer_sheet_included': false,
    'answers_count': 0,
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Harness h, {
  String questionPrefix = 'Q',
  String solutionPrefix = 'S',
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(h.controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: QpicTheme.dark,
      home: ReviewScreen(
        controller: h.controller,
        questionPrefix: questionPrefix,
        solutionPrefix: solutionPrefix,
        onFinalize: () => h.controller.finalize(
          questionPrefix: questionPrefix,
          solutionPrefix: solutionPrefix,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('download bar is hidden until a finalize succeeds', (tester) async {
    final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 1));
    h.controller.loadFromAnalyze(_analyze());
    await _pump(tester, h);

    expect(
      find.byKey(const ValueKey('review-finalize-download-bar')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('review-finalize')), findsOneWidget);
  });

  testWidgets(
      'tapping Finalize reveals only the Combined download when no per-type '
      'URLs are reported (Req 11.1)', (tester) async {
    final h = _Harness(statusCode: 200, body: _cropBody(questionsCount: 2));
    h.controller.loadFromAnalyze(_analyze());
    await _pump(tester, h);

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('review-finalize-download-bar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('review-download-combined')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('review-download-questions')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('review-download-solutions')),
      findsNothing,
    );
  });

  testWidgets(
      'Questions/Solutions buttons appear only when the engine reports their '
      'URL (Req 11.2, 11.3)', (tester) async {
    final h = _Harness(
      statusCode: 200,
      body: _cropBody(
        questionsUrl: '/api/crop/download/fin-job?kind=questions',
        solutionsUrl: '/api/crop/download/fin-job?kind=solutions',
        questionsCount: 2,
        solutionsCount: 1,
      ),
    );
    h.controller.loadFromAnalyze(_analyze());
    await _pump(tester, h);

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('review-download-combined')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('review-download-questions')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('review-download-solutions')),
      findsOneWidget,
    );
  });

  testWidgets(
      'tapping a download button streams through cropDownloadUri with kind + '
      'prefixes and confirms the save (Req 11.4)', (tester) async {
    final h = _Harness(
      statusCode: 200,
      body: _cropBody(
        questionsUrl: '/api/crop/download/fin-job?kind=questions',
        questionsCount: 2,
      ),
    );
    h.controller.loadFromAnalyze(_analyze());
    await _pump(tester, h, questionPrefix: 'QQ', solutionPrefix: 'SS');

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('review-download-combined')));
    await tester.pumpAndSettle();

    expect(h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/fin-job'
        '?kind=combined&question_prefix=QQ&solution_prefix=SS');
    expect(h.seenSuggestedNames.last, 'QQSScombined.zip');
    // The save is confirmed to the user.
    expect(find.textContaining('Saved to'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-download-questions')));
    await tester.pumpAndSettle();
    expect(h.streamedUris.last.toString(),
        'http://127.0.0.1:54321/api/crop/download/fin-job'
        '?kind=questions&question_prefix=QQ&solution_prefix=SS');
    expect(h.seenSuggestedNames.last, 'QQ.zip');
  });

  testWidgets('an engine error surfaces the detail banner and no download bar',
      (tester) async {
    final h = _Harness(
      statusCode: 404,
      body: jsonEncode(<String, dynamic>{'detail': 'Job ID not found'}),
    );
    h.controller.loadFromAnalyze(_analyze());
    await _pump(tester, h);

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('review-finalize-download-bar')),
      findsNothing,
    );
    final Text message = tester.widget(
      find.byKey(const ValueKey('review-finalize-error-message')),
    );
    expect(message.data, 'Job ID not found');
    // Items are retained so the user can retry (Req 7.7).
    expect(h.controller.items.length, 1);
  });

  testWidgets('bilingual download selector displays tabs and triggers refinalize',
      (tester) async {
    final h = _Harness(
      statusCode: 200,
      body: _cropBody(questionsCount: 2),
    );
    h.controller.loadFromAnalyze(_analyze());
    h.controller.bilingualMode = 'bilingual_horizontal';
    h.controller.bilingualModeActive = true;
    await _pump(tester, h);

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    // Verify download bar is visible
    expect(
      find.byKey(const ValueKey('review-finalize-download-bar')),
      findsOneWidget,
    );

    // Verify SegmentedButton for language selection is displayed
    expect(find.byType(SegmentedButton<String>), findsOneWidget);

    // Verify English segment is present and tap it
    final englishSegment = find.descendant(
      of: find.byKey(const ValueKey('review-finalize-download-bar')),
      matching: find.text('English'),
    );
    expect(englishSegment, findsOneWidget);
    await tester.tap(englishSegment);
    await tester.pumpAndSettle();

    // The active finalization mode should become 'english'
    expect(h.controller.activeFinalizeBilingualMode, 'english');
  });

  testWidgets('segmented button language selector is visible in standard finalization mode when active',
      (tester) async {
    final h = _Harness(
      statusCode: 200,
      body: _cropBody(questionsCount: 2),
    );
    h.controller.loadFromAnalyze(_analyze());
    h.controller.bilingualMode = null; // Standard
    h.controller.bilingualModeActive = true;
    await _pump(tester, h);

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    // Verify SegmentedButton for language selection is displayed
    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    // Standard segment should be selected
    final SegmentedButton<String> segmentedButton = tester.widget(find.byType(SegmentedButton<String>));
    expect(segmentedButton.selected, <String>{'none'});
  });

  testWidgets('language selector is hidden when bilingual mode option is false',
      (tester) async {
    final h = _Harness(
      statusCode: 200,
      body: _cropBody(questionsCount: 2),
    );
    h.controller.loadFromAnalyze(_analyze());
    h.controller.bilingualModeActive = false; // Hidden
    await _pump(tester, h);

    await tester.tap(find.byKey(const ValueKey('review-finalize')));
    await tester.pumpAndSettle();

    // Verify download bar is visible
    expect(
      find.byKey(const ValueKey('review-finalize-download-bar')),
      findsOneWidget,
    );

    // Verify SegmentedButton for language selection is NOT displayed
    expect(find.byType(SegmentedButton<String>), findsNothing);
  });
}
