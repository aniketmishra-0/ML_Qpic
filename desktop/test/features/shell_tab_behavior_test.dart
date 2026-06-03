// Widget tests for the application-shell tab behaviour (task 6.3).
//
// These verify the contract the shell promises in Requirement 4:
//
//  * 4.2 — exactly five tool tabs labeled Auto Crop / Manual Crop /
//          Rename Batch / PDF Enhancer / Tools.
//  * 4.3 — selecting a tab shows only that tool's view and hides the other
//          four, and the shell's `IndexedStack` keeps every view mounted so
//          each one retains its state across tab switches (text entered in one
//          tab survives switching away and back).
//  * 4.4 — the default selected tab on launch is Auto Crop.
//
// The state-retention case uses a custom `toolViewBuilder` whose per-tool
// widgets own their `TextEditingController` in `State`. That makes the test
// meaningful: the entered text can only survive a tab switch if the shell kept
// the widget's `State` alive (i.e. the `IndexedStack` did not tear the view
// down). A second case exercises the real `ToolPlaceholder` interaction counter
// to confirm the shipped shell retains state the same way.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/shell/app_shell.dart';

/// A minimal stateful tool view that owns its [TextEditingController] in
/// [State]. If the shell were to rebuild the view from scratch on a tab switch,
/// this controller (and its text) would be recreated and the text would be
/// lost — so persistence of the text proves the view's state was retained.
class _StatefulToolField extends StatefulWidget {
  const _StatefulToolField({required super.key, required this.tool});

  final QpicTool tool;

  @override
  State<_StatefulToolField> createState() => _StatefulToolFieldState();
}

class _StatefulToolFieldState extends State<_StatefulToolField> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 240,
        child: TextField(
          key: ValueKey<String>('field-${widget.tool.name}'),
          controller: _controller,
          decoration: InputDecoration(labelText: widget.tool.label),
        ),
      ),
    );
  }
}

/// Wraps [AppShell] in a themed [MaterialApp]. When [toolViewBuilder] is null
/// the shell renders its default [ToolPlaceholder]s.
Widget _host(
  ThemeController controller, {
  Widget Function(QpicTool tool, int subTab)? toolViewBuilder,
}) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: AppShell(
      themeController: controller,
      toolViewBuilder: toolViewBuilder,
    ),
  );
}

/// Widens the test surface so the app bar (brand + five tabs + Help + the
/// segmented theme switcher) lays out without the actions overlapping the
/// tabs. At the default 800×600 surface the switcher sits on top of the tab
/// hit-targets, which would make tab taps land on the wrong widget.
void _useWideSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('AppShell tab behaviour', () {
    testWidgets(
        'exposes exactly the five tool tabs in order (Requirement 4.2)',
        (tester) async {
      final theme = ThemeController();
      addTearDown(theme.dispose);
      _useWideSurface(tester);

      await tester.pumpWidget(_host(theme));

      // All five tabs are present...
      expect(find.byKey(const ValueKey('tool-tab-autoCrop')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-tab-manualCrop')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-tab-renameBatch')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-tab-pdfEnhancer')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-tab-tools')), findsOneWidget);

      // ...and there are exactly five of them, matching the QpicTool enum.
      expect(QpicTool.values, hasLength(5));
    });

    testWidgets('defaults to the Auto Crop tab on launch (Requirement 4.4)',
        (tester) async {
      final theme = ThemeController();
      addTearDown(theme.dispose);
      _useWideSurface(tester);

      await tester.pumpWidget(_host(theme));

      // The IndexedStack is seeded to the Auto Crop index (0).
      final IndexedStack stack = tester.widget(
        find.byKey(const ValueKey('shell-tool-stack')),
      );
      expect(stack.index, QpicTool.autoCrop.index);
      expect(stack.index, 0);

      // Only the Auto Crop view is on stage; the other four are hidden.
      expect(
        find.byKey(const ValueKey('tool-title-Auto Crop')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tool-title-Manual Crop')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('tool-title-Rename Batch')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('tool-title-PDF Enhancer')), findsNothing);
      expect(find.byKey(const ValueKey('tool-title-PDF Tools')), findsNothing);
    });

    testWidgets(
        'selecting a tab shows only that view and hides the others '
        '(Requirement 4.3)', (tester) async {
      final theme = ThemeController();
      addTearDown(theme.dispose);
      _useWideSurface(tester);

      await tester.pumpWidget(_host(theme));

      Future<void> selectAndExpect(
        String tabKey,
        int expectedIndex,
        String visibleTitleKey,
        List<String> hiddenTitleKeys,
      ) async {
        await tester.tap(find.byKey(ValueKey<String>(tabKey)));
        await tester.pumpAndSettle();

        final IndexedStack stack = tester.widget(
          find.byKey(const ValueKey('shell-tool-stack')),
        );
        expect(stack.index, expectedIndex);

        expect(
          find.byKey(ValueKey<String>(visibleTitleKey)),
          findsOneWidget,
        );
        for (final hidden in hiddenTitleKeys) {
          expect(find.byKey(ValueKey<String>(hidden)), findsNothing);
        }
      }

      await selectAndExpect(
        'tool-tab-manualCrop',
        QpicTool.manualCrop.index,
        'tool-title-Manual Crop',
        const <String>[
          'tool-title-Auto Crop',
          'tool-title-Rename Batch',
          'tool-title-PDF Enhancer',
          'tool-title-PDF Tools',
        ],
      );

      await selectAndExpect(
        'tool-tab-pdfEnhancer',
        QpicTool.pdfEnhancer.index,
        'tool-title-PDF Enhancer',
        const <String>[
          'tool-title-Auto Crop',
          'tool-title-Manual Crop',
          'tool-title-Rename Batch',
          'tool-title-PDF Tools',
        ],
      );

      await selectAndExpect(
        'tool-tab-tools',
        QpicTool.tools.index,
        'tool-title-PDF Tools',
        const <String>[
          'tool-title-Auto Crop',
          'tool-title-Manual Crop',
          'tool-title-Rename Batch',
          'tool-title-PDF Enhancer',
        ],
      );

      await selectAndExpect(
        'tool-tab-autoCrop',
        QpicTool.autoCrop.index,
        'tool-title-Auto Crop',
        const <String>[
          'tool-title-Manual Crop',
          'tool-title-Rename Batch',
          'tool-title-PDF Enhancer',
          'tool-title-PDF Tools',
        ],
      );
    });

    testWidgets(
        'tab switching preserves each view state — text entered in one tab '
        'persists when switching away and back (Requirement 4.3)',
        (tester) async {
      final theme = ThemeController();
      addTearDown(theme.dispose);
      _useWideSurface(tester);

      await tester.pumpWidget(
        _host(
          theme,
          toolViewBuilder: (tool, subTab) => _StatefulToolField(
            key: ValueKey<String>('tool-view-${tool.name}'),
            tool: tool,
          ),
        ),
      );

      const autoText = 'auto crop notes';
      const manualText = 'manual crop notes';
      const pdfEnhancerText = 'pdf enhancer notes';
      const toolsText = 'tools notes';

      // Enter text in the default (Auto Crop) view.
      await tester.enterText(
        find.byKey(const ValueKey('field-autoCrop')),
        autoText,
      );
      await tester.pump();

      // Switch to Manual Crop and enter different text.
      await tester.tap(find.byKey(const ValueKey('tool-tab-manualCrop')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-manualCrop')),
        manualText,
      );
      await tester.pump();

      // Switch to PDF Enhancer and enter a third value.
      await tester.tap(find.byKey(const ValueKey('tool-tab-pdfEnhancer')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-pdfEnhancer')),
        pdfEnhancerText,
      );
      await tester.pump();

      // Switch to Tools and enter a fourth value.
      await tester.tap(find.byKey(const ValueKey('tool-tab-tools')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-tools')),
        toolsText,
      );
      await tester.pump();

      // Back to Auto Crop — its text must still be there.
      await tester.tap(find.byKey(const ValueKey('tool-tab-autoCrop')));
      await tester.pumpAndSettle();
      final TextField autoField = tester.widget(
        find.byKey(const ValueKey('field-autoCrop')),
      );
      expect(autoField.controller!.text, autoText);

      // Manual Crop's text survived too.
      await tester.tap(find.byKey(const ValueKey('tool-tab-manualCrop')));
      await tester.pumpAndSettle();
      final TextField manualField = tester.widget(
        find.byKey(const ValueKey('field-manualCrop')),
      );
      expect(manualField.controller!.text, manualText);

      // PDF Enhancer's text survived too.
      await tester.tap(find.byKey(const ValueKey('tool-tab-pdfEnhancer')));
      await tester.pumpAndSettle();
      final TextField pdfEnhancerField = tester.widget(
        find.byKey(const ValueKey('field-pdfEnhancer')),
      );
      expect(pdfEnhancerField.controller!.text, pdfEnhancerText);

      // And so did Tools'.
      await tester.tap(find.byKey(const ValueKey('tool-tab-tools')));
      await tester.pumpAndSettle();
      final TextField toolsField = tester.widget(
        find.byKey(const ValueKey('field-tools')),
      );
      expect(toolsField.controller!.text, toolsText);
    });

    testWidgets(
        'the shipped ToolPlaceholder retains its interaction state across '
        'tab switches (Requirement 4.3)', (tester) async {
      final theme = ThemeController();
      addTearDown(theme.dispose);
      _useWideSurface(tester);

      // No custom builder → the real ToolPlaceholder views are used.
      await tester.pumpWidget(_host(theme));

      // Counter starts at zero on the default Auto Crop view.
      expect(
        find.byKey(const ValueKey('tool-counter-Auto Crop')),
        findsOneWidget,
      );

      // Interact three times.
      for (var i = 0; i < 3; i++) {
        await tester.tap(
          find.byKey(const ValueKey('tool-interact-Auto Crop')),
        );
        await tester.pump();
      }
      expect(find.text('Interactions: 3'), findsOneWidget);

      // Visit another tab and come back.
      await tester.tap(find.byKey(const ValueKey('tool-tab-renameBatch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tool-tab-autoCrop')));
      await tester.pumpAndSettle();

      // The Auto Crop view kept its counter (state was not rebuilt).
      expect(find.text('Interactions: 3'), findsOneWidget);
    });
  });
}
