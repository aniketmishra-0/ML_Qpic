// Render smoke tests for AutoCropView (Requirements 5.1, 5.2, 5.3).
//
// These confirm the form renders every control with its stable key and that
// the controls reflect / mutate the controller (including the bounds-clamping
// surfaced through the UI). The submit-guard behaviour is task 9.4, so it is
// not exercised here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart';
import 'package:qpic_desktop/features/auto_crop/auto_crop_view.dart';

Widget _host(AutoCropController controller, {VoidCallback? onSubmit}) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(
      body: AutoCropView(controller: controller, onSubmit: onSubmit),
    ),
  );
}

void main() {
  testWidgets('renders the Questions/Solutions toggles and page-range fields',
      (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('auto-crop-has-questions')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-has-answers')), findsOneWidget);
    // Both toggles default on, so both page-range fields show.
    expect(find.byKey(const ValueKey('auto-crop-question-pages')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-answer-pages')), findsOneWidget);
  });

  testWidgets('renders the mode toggles and the numbering selector',
      (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('auto-crop-smart-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-online-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-answer-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-numbering')), findsOneWidget);
  });

  testWidgets('renders the output configuration controls', (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const ValueKey('auto-crop-question-prefix')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-solution-prefix')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-start-number')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-image-format')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-dpi')), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-crop-padding')), findsOneWidget);
  });

  testWidgets('hides the page-range field when its toggle is off',
      (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    controller.hasQuestions = false;
    await tester.pump();

    expect(find.byKey(const ValueKey('auto-crop-question-pages')), findsNothing);
    expect(find.byKey(const ValueKey('auto-crop-answer-pages')), findsOneWidget);
  });

  testWidgets('shows the JPG quality slider only when JPG is selected',
      (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    // PNG by default → no quality slider.
    expect(find.byKey(const ValueKey('auto-crop-jpg-quality')), findsNothing);

    controller.imageFormat = CropImageFormat.jpg;
    await tester.pump();
    expect(find.byKey(const ValueKey('auto-crop-jpg-quality')), findsOneWidget);
  });

  testWidgets('typing an over-long prefix is truncated to 10 chars',
      (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    await tester.enterText(
      find.byKey(const ValueKey('auto-crop-question-prefix')),
      'ABCDEFGHIJKLMNOP',
    );
    await tester.pump();
    expect(controller.questionPrefix, 'ABCDEFGHIJ');
  });

  testWidgets('the start-number field clamps an over-max entry',
      (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    await tester.enterText(
      find.byKey(const ValueKey('auto-crop-start-number')),
      '999999',
    );
    await tester.pump();
    expect(controller.startNumber, AutoCropBounds.startNumberMax);
  });

  testWidgets('the submit button label tracks Smart mode', (tester) async {
    final controller = AutoCropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller, onSubmit: () {}));

    expect(find.widgetWithText(FilledButton, 'Crop'), findsOneWidget);

    controller.smartMode = true;
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Analyze & Review'), findsOneWidget);
  });
}
