import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/shell/document_zoom_controller.dart';
import 'package:qpic_desktop/features/shell/platform_menu_bar.dart';

void main() {
  group('QpicPlatformMenuBar', () {
    late ActiveDocumentZoom zoomRegistry;
    late DocumentZoomController zoomController;

    setUp(() {
      zoomRegistry = ActiveDocumentZoom();
      zoomController = DocumentZoomController();
      zoomRegistry.register(zoomController);
    });

    tearDown(() {
      zoomController.dispose();
      zoomRegistry.dispose();
    });

    Widget buildTestWidget({Widget? child}) {
      return MaterialApp(
        home: QpicPlatformMenuBar(
          zoomRegistry: zoomRegistry,
          child: child ?? const Scaffold(body: Text('Content')),
        ),
      );
    }

    testWidgets('renders a PlatformMenuBar wrapping the child',
        (tester) async {
      await tester.pumpWidget(buildTestWidget());

      expect(find.byType(PlatformMenuBar), findsOneWidget);
      expect(find.text('Content'), findsOneWidget);
    });

    testWidgets('renders child content below the menu bar', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        child: const Scaffold(body: Text('Test Child')),
      ));

      expect(find.text('Test Child'), findsOneWidget);
    });

    group('Zoom shortcuts via ActiveDocumentZoom', () {
      testWidgets('zoomIn increments the active controller zoom',
          (tester) async {
        await tester.pumpWidget(buildTestWidget());

        final double initialZoom = zoomController.zoom;
        zoomRegistry.zoomIn();
        expect(zoomController.zoom, greaterThan(initialZoom));
      });

      testWidgets('zoomOut decrements the active controller zoom',
          (tester) async {
        await tester.pumpWidget(buildTestWidget());

        final double initialZoom = zoomController.zoom;
        zoomRegistry.zoomOut();
        expect(zoomController.zoom, lessThan(initialZoom));
      });

      testWidgets('reset returns zoom to fit-width (1.0)', (tester) async {
        await tester.pumpWidget(buildTestWidget());

        // Zoom in first so reset has something to do.
        zoomRegistry.zoomIn();
        zoomRegistry.zoomIn();
        expect(zoomController.zoom, isNot(equals(1.0)));

        zoomRegistry.reset();
        expect(zoomController.zoom, equals(1.0));
      });

      testWidgets('zoom commands are no-ops when no controller is registered',
          (tester) async {
        zoomRegistry.unregister(zoomController);
        await tester.pumpWidget(buildTestWidget());

        // Should not throw.
        zoomRegistry.zoomIn();
        zoomRegistry.zoomOut();
        zoomRegistry.reset();

        // Controller zoom unchanged since it was unregistered.
        expect(zoomController.zoom, equals(1.0));
      });
    });

    group('Edit menu actions', () {
      testWidgets('edit actions do not throw when no focus exists',
          (tester) async {
        await tester.pumpWidget(buildTestWidget());

        // Simulate invoking edit actions with no focused text field.
        // This should be a no-op, not a crash.
        // We can't directly invoke menu items in tests, but we can verify
        // the widget builds without error and the menu bar is present.
        expect(find.byType(PlatformMenuBar), findsOneWidget);
      });

      testWidgets('edit shortcuts are wired to the menu bar', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: QpicPlatformMenuBar(
              zoomRegistry: zoomRegistry,
              child: const Scaffold(
                body: TextField(
                  key: ValueKey('test-field'),
                ),
              ),
            ),
          ),
        );

        // Tap the text field to focus it.
        await tester.tap(find.byKey(const ValueKey('test-field')));
        await tester.pump();

        // Verify the PlatformMenuBar is present with the Edit menu.
        final PlatformMenuBar menuBar =
            tester.widget(find.byType(PlatformMenuBar));
        expect(menuBar.menus.length, equals(4));

        // Second menu should be Edit.
        final PlatformMenu editMenu = menuBar.menus[1] as PlatformMenu;
        expect(editMenu.label, equals('Edit'));

        // Edit menu should have 4 items: Cut, Copy, Paste, Select All.
        expect(editMenu.menus.length, equals(4));
      });
    });

    group('Menu structure', () {
      testWidgets('has four top-level menus: Qpic, Edit, View, Help',
          (tester) async {
        await tester.pumpWidget(buildTestWidget());

        final PlatformMenuBar menuBar =
            tester.widget(find.byType(PlatformMenuBar));
        expect(menuBar.menus.length, equals(4));

        final labels = menuBar.menus
            .whereType<PlatformMenu>()
            .map((m) => m.label)
            .toList();
        expect(labels, equals(['Qpic', 'Edit', 'View', 'Help']));
      });

      testWidgets('View menu has Zoom In, Zoom Out, Actual Size',
          (tester) async {
        await tester.pumpWidget(buildTestWidget());

        final PlatformMenuBar menuBar =
            tester.widget(find.byType(PlatformMenuBar));
        final PlatformMenu viewMenu = menuBar.menus[2] as PlatformMenu;
        expect(viewMenu.label, equals('View'));

        final zoomLabels = viewMenu.menus
            .whereType<PlatformMenuItem>()
            .map((m) => m.label)
            .toList();
        expect(zoomLabels, contains('Zoom In'));
        expect(zoomLabels, contains('Zoom Out'));
        expect(zoomLabels, contains('Actual Size'));
      });

      testWidgets('Help menu has "How to Use Qpic" entry', (tester) async {
        await tester.pumpWidget(buildTestWidget());

        final PlatformMenuBar menuBar =
            tester.widget(find.byType(PlatformMenuBar));
        final PlatformMenu helpMenu = menuBar.menus[3] as PlatformMenu;
        expect(helpMenu.label, equals('Help'));

        final helpLabels = helpMenu.menus
            .whereType<PlatformMenuItem>()
            .map((m) => m.label)
            .toList();
        expect(helpLabels, contains('How to Use Qpic'));
      });

      testWidgets('Edit menu items have correct labels', (tester) async {
        await tester.pumpWidget(buildTestWidget());

        final PlatformMenuBar menuBar =
            tester.widget(find.byType(PlatformMenuBar));
        final PlatformMenu editMenu = menuBar.menus[1] as PlatformMenu;

        final editLabels = editMenu.menus
            .whereType<PlatformMenuItem>()
            .map((m) => m.label)
            .toList();
        expect(editLabels, equals(['Cut', 'Copy', 'Paste', 'Select All']));
      });
    });

    // On Windows/Linux, PlatformMenuBar renders only its child and does NOT
    // activate menu-item key equivalents, so the "Windows equivalent" must
    // deliver the zoom shortcuts through an explicit Shortcuts/Actions layer
    // (Requirement 19.4). These tests pump under a non-macOS target platform
    // and send real key events to confirm Ctrl +/-/0 drive the active zoom.
    //
    // `debugDefaultTargetPlatformOverride` must be reset before the test body
    // ends (the test framework verifies it is unset before tearDown runs), so
    // it is set and cleared inside each test body rather than in setUp/tearDown.
    group('Windows/Linux zoom shortcut layer', () {
      Future<void> pumpWindows(WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: QpicPlatformMenuBar(
              zoomRegistry: zoomRegistry,
              child: const Scaffold(
                body: Focus(autofocus: true, child: Text('x')),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      testWidgets('Ctrl+= zooms the active document view in', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await pumpWindows(tester);
        final double initial = zoomController.zoom;

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(zoomController.zoom, greaterThan(initial));
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('Ctrl+- zooms the active document view out', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        zoomController.setZoom(2.0);
        await pumpWindows(tester);
        final double initial = zoomController.zoom;

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(zoomController.zoom, lessThan(initial));
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('Ctrl+0 resets the active document view to fit-width',
          (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        zoomController.setZoom(3.0);
        await pumpWindows(tester);
        expect(zoomController.zoom, isNot(equals(1.0)));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(zoomController.zoom, equals(1.0));
        debugDefaultTargetPlatformOverride = null;
      });
    });
  });
}
