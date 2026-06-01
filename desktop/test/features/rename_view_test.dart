// Render + interaction tests for RenameView (Requirements 12.1, 12.2).
//
// These confirm the Rename Batch form renders every naming/output control with
// its stable key, that the controls reflect / mutate the controller (including
// the bounds-clamping surfaced through the UI), and that the client-side live
// before/after preview appears once items are loaded. The PDF-to-images and
// rename-&-download session flow is task 15.2, so it is not exercised here.
//
// RenameController debounces its `/api/rename/preview` round-trip behind a
// 300ms timer (see RenameController._schedulePreview). With no ApiClient wired
// (the live engine client lands in task 15.2) that timer just no-ops, but the
// widget tester still flags it as a pending timer at the end of a test body, so
// each test that mutates the controller drains it with [_settlePreview].

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/rename/rename_controller.dart';
import 'package:qpic_desktop/features/rename/rename_view.dart';

Widget _host(
  RenameController controller, {
  VoidCallback? onPickFiles,
  VoidCallback? onRename,
  String? errorText,
  bool busy = false,
}) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(
      body: RenameView(
        controller: controller,
        onPickFiles: onPickFiles,
        onRename: onRename,
        errorText: errorText,
        busy: busy,
      ),
    ),
  );
}

/// Drains the controller's 300ms preview debounce timer so the widget tester
/// does not report a pending timer when the tree is disposed.
Future<void> _settlePreview(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 350));

void main() {
  testWidgets('renders the naming controls (pattern, start, padding)',
      (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('rename-pattern')), findsOneWidget);
    expect(find.byKey(const ValueKey('rename-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('rename-padding')), findsOneWidget);
  });

  testWidgets('renders the output-format selector', (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('rename-output-format')), findsOneWidget);
  });

  testWidgets('shows the JPG quality slider only for jpg/jpeg formats',
      (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    // Original by default → no quality slider.
    expect(find.byKey(const ValueKey('rename-jpg-quality')), findsNothing);

    controller.outputFormat = RenameOutputFormat.jpg;
    await tester.pump();
    expect(find.byKey(const ValueKey('rename-jpg-quality')), findsOneWidget);

    controller.outputFormat = RenameOutputFormat.jpeg;
    await tester.pump();
    expect(find.byKey(const ValueKey('rename-jpg-quality')), findsOneWidget);

    // A non-JPG format hides it again.
    controller.outputFormat = RenameOutputFormat.png;
    await tester.pump();
    expect(find.byKey(const ValueKey('rename-jpg-quality')), findsNothing);

    await _settlePreview(tester);
  });

  testWidgets('the start-number field clamps an over-max entry',
      (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    await tester.enterText(
      find.byKey(const ValueKey('rename-start')),
      '9999999',
    );
    await tester.pump();
    expect(controller.start, RenameBounds.startMax);

    await _settlePreview(tester);
  });

  testWidgets('the padding field clamps an over-max entry', (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    await tester.enterText(
      find.byKey(const ValueKey('rename-padding')),
      '20',
    );
    await tester.pump();
    expect(controller.padding, RenameBounds.paddingMax);

    await _settlePreview(tester);
  });

  testWidgets('typing a pattern updates the controller', (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    await tester.enterText(
      find.byKey(const ValueKey('rename-pattern')),
      'page-#',
    );
    await tester.pump();
    expect(controller.pattern, 'page-#');

    await _settlePreview(tester);
  });

  testWidgets('the preview is hidden until items are loaded', (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('rename-preview-list')), findsNothing);

    controller.pattern = 'Q#';
    controller.addItems([
      RenameItem(name: 'a.png', sizeBytes: 0),
      RenameItem(name: 'b.png', sizeBytes: 0),
    ]);
    await tester.pump();

    expect(find.byKey(const ValueKey('rename-preview-list')), findsOneWidget);
    // The client-side before/after pairs render the planned names.
    expect(find.text('Q1.png'), findsOneWidget);
    expect(find.text('Q2.png'), findsOneWidget);

    await _settlePreview(tester);
  });

  testWidgets('the file count reflects loaded items', (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.text('No files added'), findsOneWidget);

    controller.addItems([RenameItem(name: 'a.png', sizeBytes: 0)]);
    await tester.pump();
    expect(find.text('1 file loaded'), findsOneWidget);

    controller.addItems([RenameItem(name: 'b.png', sizeBytes: 0)]);
    await tester.pump();
    expect(find.text('2 files loaded'), findsOneWidget);

    await _settlePreview(tester);
  });

  testWidgets('the rename button is disabled until items are loaded',
      (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    var renamed = 0;
    await tester.pumpWidget(_host(controller, onRename: () => renamed++));

    final FilledButton emptyButton = tester.widget(
      find.byKey(const ValueKey('rename-submit')),
    );
    expect(emptyButton.onPressed, isNull);

    controller.addItems([RenameItem(name: 'a.png', sizeBytes: 0)]);
    await tester.pump();

    final FilledButton loadedButton = tester.widget(
      find.byKey(const ValueKey('rename-submit')),
    );
    expect(loadedButton.onPressed, isNotNull);
    expect(renamed, 0);

    await _settlePreview(tester);
  });

  testWidgets('surfaces an error banner when errorText is provided',
      (tester) async {
    final controller = RenameController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(controller, errorText: 'Something went wrong.'),
    );

    expect(find.byKey(const ValueKey('rename-error')), findsOneWidget);
    expect(find.text('Something went wrong.'), findsOneWidget);
  });
}
