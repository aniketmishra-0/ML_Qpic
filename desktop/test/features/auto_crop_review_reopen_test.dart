// Reproduction test for the "review does not reopen on a second analyze" bug.
//
// Drives the exact open → close → reopen flow that `app.dart` performs, but
// invokes the host State methods directly (via a GlobalKey) so the async
// submit + rebuild ordering is deterministic and we observe the widget tree
// the same way the running app renders it.

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
import 'package:qpic_desktop/features/review/review_controller.dart';
import 'package:qpic_desktop/features/review/review_screen.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter({required this.body});
  final String body;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(body, 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

String _analyzeBody() => jsonEncode(<String, dynamic>{
      'job_id': 'job-1',
      'total_pages': 1,
      'method_used': 'text',
      'pages': <Map<String, dynamic>>[
        <String, dynamic>{
          'page': 1,
          'width_pt': 600,
          'height_pt': 800,
          'preview_url': '',
        },
      ],
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'q_num': '1',
          'is_solution': false,
          'segments': <Map<String, dynamic>>[
            <String, dynamic>{
              'page': 1,
              'x_start_pct': 10,
              'x_end_pct': 50,
              'y_start_pct': 10,
              'y_end_pct': 50,
            },
          ],
          'source': 'auto',
          'flagged': false,
        },
      ],
      'notes': <Map<String, dynamic>>[],
      'needs_review': false,
      'answer_key_count': 0,
    });

/// Reproduces app.dart's auto-crop ↔ review host wiring.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.auto, required this.review});
  final AutoCropController auto;
  final ReviewController review;
  @override
  HostState createState() => HostState();
}

class HostState extends State<_Host> {
  bool open = false;

  Future<void> submit() async {
    await widget.auto.submit();
    final analysis = widget.auto.analyzeResult;
    if (analysis != null) {
      widget.review.loadFromAnalyze(analysis);
      widget.auto.consumeAnalyzeResult();
      setState(() => open = true);
    }
  }

  void close() {
    widget.review.reset();
    setState(() => open = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: QpicTheme.dark,
      home: Scaffold(
        body: AnimatedBuilder(
          animation: widget.auto,
          builder: (context, _) {
            if (open) {
              return ReviewScreen(
                key: const ValueKey<String>('tool-view-autoCrop'),
                controller: widget.review,
                onClose: close,
              );
            }
            return AutoCropView(
              key: const ValueKey<String>('tool-view-autoCrop'),
              controller: widget.auto,
              onSubmit: submit,
            );
          },
        ),
      ),
    );
  }
}

void main() {
  testWidgets('review reopens on a second analyze after closing',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dio = Dio()..httpClientAdapter = _Adapter(body: _analyzeBody());
    final apiClient = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
    final auto = AutoCropController(apiClient: apiClient)
      ..setFile(bytes: const <int>[1, 2, 3], filename: 'paper.pdf')
      ..smartMode = true
      ..questionPages = '1-5'
      ..answerPages = '7-10';
    addTearDown(auto.dispose);
    final review = ReviewController(apiClient: apiClient);
    addTearDown(review.dispose);

    final key = GlobalKey<HostState>();
    await tester.pumpWidget(_Host(key: key, auto: auto, review: review));

    Future<void> doSubmit() async {
      await tester.runAsync(() => key.currentState!.submit());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 1) First analyze opens the review canvas.
    await doSubmit();
    expect(key.currentState!.open, isTrue,
        reason: 'first analyze should set open=true');
    expect(find.byKey(const ValueKey('review-canvas')), findsOneWidget,
        reason: 'first analyze should render the review canvas');

    // 2) Back returns to the form.
    key.currentState!.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('auto-crop-submit')), findsOneWidget,
        reason: 'back should return to the form');

    // 3) Second analyze must reopen the review canvas.
    await doSubmit();
    expect(key.currentState!.open, isTrue,
        reason: 'second analyze should set open=true');
    expect(find.byKey(const ValueKey('review-canvas')), findsOneWidget,
        reason: 'second analyze should reopen the review canvas');
  });
}
