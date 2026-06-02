// Widget tests for the Auto Crop form submit guards (Task 9.4 —
// Requirements 5.5, 5.6, 5.7).
//
// Unlike `auto_crop_submit_test.dart`, which drives the AutoCropController
// directly, these tests drive the *actual* AutoCropView widget through the
// WidgetTester: a user toggles switches, types into the page-range fields via
// their stable ValueKeys, and taps the real Crop button. They verify that:
//
//   * Questions on with an empty question range blocks submission, shows the
//     ERR_QUESTION_PAGES_REQUIRED prompt, and preserves the entered values
//     (Requirement 5.5),
//   * Solutions on with an empty answer range does the same with the
//     ERR_ANSWER_PAGES_REQUIRED prompt (Requirement 5.6),
//   * both toggles off blocks submission with the ERR_NOTHING_SELECTED prompt
//     (Requirement 5.7),
//
// and that in every blocked case NO crop request is issued and the user's
// entered values remain in the form.
//
// The engine is faked with a Dio HttpClientAdapter that records every request
// and would return a success body — so any leaked request is observable. A
// blocked submit must leave its request count at zero.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_view.dart';

/// A fake adapter that records every request it receives and returns a fixed
/// success body. If the form ever leaks a request past the guards, this
/// adapter's [requestCount] will be non-zero and the test will fail.
class _RecordingAdapter implements HttpClientAdapter {
  int requestCount = 0;
  RequestOptions? lastRequest;

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
      jsonEncode(<String, dynamic>{
        'job_id': 'job-1',
        'total_questions': 0,
        'stitched_questions': 0,
        'method_used': 'text',
        'download_url': '/api/crop/download/job-1',
        'questions_download_url': null,
        'solutions_download_url': null,
        'questions_count': 0,
        'solutions_count': 0,
        'answer_sheet_included': false,
        'answers_count': 0,
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Bundles a controller wired to a request-recording ApiClient.
class _Harness {
  _Harness() {
    adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
    controller = AutoCropController(apiClient: apiClient)
      ..smartMode = false
      // A PDF is loaded so the only thing that can block a crop is the guard
      // under test, not a missing file.
      ..setFile(bytes: const <int>[1, 2, 3], filename: 'paper.pdf');
  }

  late final _RecordingAdapter adapter;
  late final AutoCropController controller;
}

Widget _host(AutoCropController controller) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(
      body: AutoCropView(
        controller: controller,
        // Wire the real submit path so tapping Crop runs the guards.
        onSubmit: controller.submit,
      ),
    ),
  );
}

/// Reads back the current text shown in a page-range field by its key.
String _fieldText(WidgetTester tester, String key) {
  final field = tester.widget<TextField>(find.byKey(ValueKey<String>(key)));
  return field.controller?.text ?? '';
}

/// Scrolls the Crop button into view (the form lives in a SingleChildScrollView
/// taller than the test viewport) and taps it.
Future<void> _tapSubmit(WidgetTester tester) async {
  final submitButton = find.byKey(const ValueKey<String>('auto-crop-submit'));
  await tester.ensureVisible(submitButton);
  await tester.pumpAndSettle();
  await tester.tap(submitButton);
  await tester.pumpAndSettle();
}

void main() {
  final errorBanner = find.byKey(const ValueKey<String>('auto-crop-error'));

  testWidgets(
    'Questions on with an empty question range blocks the crop, shows the '
    'prompt, preserves values, and sends no request (Req 5.5)',
    (tester) async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await tester.pumpWidget(_host(h.controller));

      // Both toggles default on. Fill the answer range but leave the question
      // range empty, then attempt to crop.
      await tester.enterText(
        find.byKey(const ValueKey<String>('auto-crop-answer-pages')),
        '7-10',
      );
      await tester.pump();

      await _tapSubmit(tester);

      // No request was issued.
      expect(h.adapter.requestCount, 0);

      // The matching prompt is shown.
      expect(errorBanner, findsOneWidget);
      expect(
        find.text(AutoCropController.errQuestionPagesRequired),
        findsOneWidget,
      );

      // The entered values are preserved in the form and controller.
      expect(_fieldText(tester, 'auto-crop-answer-pages'), '7-10');
      expect(h.controller.answerPages, '7-10');
      expect(h.controller.questionPages, '');
      expect(h.controller.result, isNull);
    },
  );

  testWidgets(
    'Solutions on with an empty answer range blocks the crop, shows the '
    'prompt, preserves values, and sends no request (Req 5.6)',
    (tester) async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await tester.pumpWidget(_host(h.controller));

      // Fill the question range but leave the answer range empty.
      await tester.enterText(
        find.byKey(const ValueKey<String>('auto-crop-question-pages')),
        '1-5',
      );
      await tester.pump();

      await _tapSubmit(tester);

      expect(h.adapter.requestCount, 0);

      expect(errorBanner, findsOneWidget);
      expect(
        find.text(AutoCropController.errAnswerPagesRequired),
        findsOneWidget,
      );

      expect(_fieldText(tester, 'auto-crop-question-pages'), '1-5');
      expect(h.controller.questionPages, '1-5');
      expect(h.controller.answerPages, '');
      expect(h.controller.result, isNull);
    },
  );

  testWidgets(
    'Both toggles off blocks the crop with the nothing-selected prompt and '
    'sends no request (Req 5.7)',
    (tester) async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await tester.pumpWidget(_host(h.controller));

      // Turn both toggles off via their switches.
      await tester.tap(
        find.byKey(const ValueKey<String>('auto-crop-has-questions')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('auto-crop-has-answers')),
      );
      await tester.pump();

      // Both toggles are now off, so neither page-range field is shown.
      expect(
        find.byKey(const ValueKey<String>('auto-crop-question-pages')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('auto-crop-answer-pages')),
        findsNothing,
      );

      await _tapSubmit(tester);

      expect(h.adapter.requestCount, 0);

      expect(errorBanner, findsOneWidget);
      expect(
        find.text(AutoCropController.errNothingSelected),
        findsOneWidget,
      );

      // The toggle state the user set is preserved.
      expect(h.controller.hasQuestions, isFalse);
      expect(h.controller.hasAnswers, isFalse);
      expect(h.controller.result, isNull);
    },
  );

  testWidgets(
    'Nothing-selected prompt preserves the ranges the user had typed before '
    'turning the toggles off (Req 5.7)',
    (tester) async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await tester.pumpWidget(_host(h.controller));

      // Type ranges while both toggles are on...
      await tester.enterText(
        find.byKey(const ValueKey<String>('auto-crop-question-pages')),
        '1-5',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('auto-crop-answer-pages')),
        '7-10',
      );
      await tester.pump();

      // ...then turn both off and attempt to crop.
      await tester.tap(
        find.byKey(const ValueKey<String>('auto-crop-has-questions')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('auto-crop-has-answers')),
      );
      await tester.pump();

      await _tapSubmit(tester);

      expect(h.adapter.requestCount, 0);
      expect(
        find.text(AutoCropController.errNothingSelected),
        findsOneWidget,
      );

      // The page ranges the user entered are retained on the controller even
      // though the fields are hidden, so re-enabling a toggle restores them.
      expect(h.controller.questionPages, '1-5');
      expect(h.controller.answerPages, '7-10');
    },
  );

  testWidgets(
    'A fully valid form issues exactly one crop request (guards pass) (Req '
    '5.5, 5.6, 5.7 negative case)',
    (tester) async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await tester.pumpWidget(_host(h.controller));

      await tester.enterText(
        find.byKey(const ValueKey<String>('auto-crop-question-pages')),
        '1-5',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('auto-crop-answer-pages')),
        '7-10',
      );
      await tester.pump();

      await _tapSubmit(tester);

      // Guards passed → exactly one /api/crop request was issued.
      expect(h.adapter.requestCount, 1);
      expect(h.adapter.lastRequest?.path, '/api/crop');
      expect(errorBanner, findsNothing);
    },
  );
}
