// Widget tests for the in-app Help walkthrough (Requirements 19.1, 19.2, 19.5).
//
// These confirm Help opens with the three walkthrough tabs (overall guide,
// How to Crop, How to Rename Batch) mirroring the web modal, that switching
// tabs swaps the step content, and that the reproduced content carries no
// external links.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/shell/help_screen.dart';

Widget _host() {
  return MaterialApp(
    theme: QpicTheme.light,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => HelpScreen.open(context),
            child: const Text('Open Help'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openHelp(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.tap(find.text('Open Help'));
  await tester.pumpAndSettle();
}

void main() {
  group('HelpScreen walkthrough', () {
    testWidgets('opens with the title and all three walkthrough tabs',
        (tester) async {
      await _openHelp(tester);

      // Title reproduces the web modal heading (19.1).
      expect(find.byKey(const ValueKey('help-title')), findsOneWidget);

      // The three tabs mirror the web walkthrough sections (19.5).
      expect(find.byKey(const ValueKey('help-tab-uiux')), findsOneWidget);
      expect(find.byKey(const ValueKey('help-tab-crop')), findsOneWidget);
      expect(find.byKey(const ValueKey('help-tab-rename')), findsOneWidget);

      expect(find.text('UI & UX of Qpic'), findsOneWidget);
      expect(find.text('How to Crop'), findsOneWidget);
      expect(find.text('How to Rename Batch'), findsOneWidget);
    });

    testWidgets('first tab shows the overall guide overview steps',
        (tester) async {
      await _openHelp(tester);

      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('App bar'), findsOneWidget);
      expect(find.text('Left panel — What to Crop'), findsOneWidget);
      expect(find.text('Right panel — Output Options'), findsOneWidget);
      expect(find.text('Light & Dark themes'), findsOneWidget);
    });

    testWidgets('switching to How to Crop swaps in the cropping steps',
        (tester) async {
      await _openHelp(tester);

      await tester.tap(find.byKey(const ValueKey('help-tab-crop')));
      await tester.pumpAndSettle();

      expect(find.text('Cropping Questions'), findsOneWidget);
      expect(find.text('Upload your PDF'), findsOneWidget);
      expect(find.text('Analyze & Review'), findsOneWidget);
      expect(find.text('Finalize & Download'), findsOneWidget);
    });

    testWidgets('switching to How to Rename Batch swaps in the rename steps',
        (tester) async {
      await _openHelp(tester);

      await tester.tap(find.byKey(const ValueKey('help-tab-rename')));
      await tester.pumpAndSettle();

      expect(find.text('Batch Renaming Images'), findsOneWidget);
      expect(find.text('Switch to Rename Batch tab'), findsOneWidget);
      expect(find.text('Upload images'), findsOneWidget);
      expect(find.text('Rename & Download ZIP'), findsOneWidget);
    });

    testWidgets('Help content contains no external links', (tester) async {
      await _openHelp(tester);

      // Walk all rendered Text widgets across every tab and assert none of the
      // reproduced copy embeds a URL / external link (19.2).
      final tabKeys = <String>['help-tab-uiux', 'help-tab-crop', 'help-tab-rename'];
      final linkPattern = RegExp(r'https?://|www\.|youtube|\.com', caseSensitive: false);

      for (final key in tabKeys) {
        await tester.tap(find.byKey(ValueKey<String>(key)));
        await tester.pumpAndSettle();

        final texts = tester.widgetList<Text>(find.byType(Text));
        for (final text in texts) {
          final data = text.data;
          if (data != null) {
            expect(
              linkPattern.hasMatch(data),
              isFalse,
              reason: 'Help copy must not contain external links: "$data"',
            );
          }
        }
      }
    });

    testWidgets('closes via the close button', (tester) async {
      await _openHelp(tester);
      expect(find.byKey(const ValueKey('help-title')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('help-close-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('help-title')), findsNothing);
    });
  });
}
