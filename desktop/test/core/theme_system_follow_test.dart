import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget-level coverage for the theme switcher behaviour that can only be
/// observed through a live [MaterialApp] (Requirements 4.6 and 4.7), plus a
/// "restart" check that ties the persisted selection back to the rendered
/// theme (4.8, 4.9).
///
/// Controller-only persistence/default/fallback behaviour is covered by
/// `theme_controller_test.dart` (task 3.3); these tests deliberately do not
/// duplicate it and instead drive a real `MaterialApp`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Theme switcher applies live without restart (Req 4.6)', () {
    testWidgets(
        'changing the selected mode re-themes the mounted app immediately',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      // Deterministic starting point independent of the host OS.
      await controller.setThemeMode(ThemeMode.light);

      late BuildContext ctx;
      await tester.pumpWidget(
        _ThemedHarness(controller: controller, onContext: (c) => ctx = c),
      );
      await tester.pumpAndSettle();

      // Light is active.
      expect(Theme.of(ctx).brightness, Brightness.light);
      expect(
        Theme.of(ctx).extension<QpicPalette>()!.success,
        QpicPalette.light.success,
      );

      // Switch to dark on the SAME mounted tree (no re-pumpWidget == no
      // restart). The MaterialApp must rebuild with the dark theme. Settle
      // through MaterialApp's built-in theme cross-fade animation.
      await controller.setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();

      expect(Theme.of(ctx).brightness, Brightness.dark);
      expect(
        Theme.of(ctx).extension<QpicPalette>()!.success,
        QpicPalette.dark.success,
      );

      // And back to light again, still without restart.
      await controller.setThemeMode(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(Theme.of(ctx).brightness, Brightness.light);
    });
  });

  group('System mode follows the OS brightness (Req 4.7)', () {
    testWidgets('resolves to the OS brightness at startup', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController(); // defaults to system
      expect(controller.themeMode, ThemeMode.system);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      late BuildContext ctx;
      await tester.pumpWidget(
        _ThemedHarness(controller: controller, onContext: (c) => ctx = c),
      );
      await tester.pump();

      expect(Theme.of(ctx).brightness, Brightness.dark);
      expect(
        Theme.of(ctx).extension<QpicPalette>()!.success,
        QpicPalette.dark.success,
      );
    });

    testWidgets('follows an OS light/dark change while running',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController(); // system

      // OS starts light.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      late BuildContext ctx;
      await tester.pumpWidget(
        _ThemedHarness(controller: controller, onContext: (c) => ctx = c),
      );
      await tester.pumpAndSettle();
      expect(Theme.of(ctx).brightness, Brightness.light);

      // OS flips to dark mid-session — the app must follow with no restart.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(ctx).brightness, Brightness.dark);

      // And back to light.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(ctx).brightness, Brightness.light);
    });

    testWidgets('an explicit Light/Dark choice ignores the OS preference',
        (tester) async {
      // The "WHILE set to System" guard in 4.7 means a fixed choice must NOT
      // track the OS brightness.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      await controller.setThemeMode(ThemeMode.light);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      late BuildContext ctx;
      await tester.pumpWidget(
        _ThemedHarness(controller: controller, onContext: (c) => ctx = c),
      );
      await tester.pumpAndSettle();

      // OS is dark, but the explicit Light choice wins.
      expect(Theme.of(ctx).brightness, Brightness.light);

      // Flipping the OS to light/dark again changes nothing.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(ctx).brightness, Brightness.light);
    });
  });

  group('Persisted selection is re-applied to the UI on restart (Req 4.8, 4.9)',
      () {
    testWidgets('a fresh launch re-themes from the stored selection',
        (tester) async {
      // First session: user picks Dark; the choice is written to storage.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final firstSession = ThemeController();
      await firstSession.setThemeMode(ThemeMode.dark);

      late BuildContext ctx;
      await tester.pumpWidget(
        _ThemedHarness(controller: firstSession, onContext: (c) => ctx = c),
      );
      await tester.pump();
      expect(Theme.of(ctx).brightness, Brightness.dark);

      // Simulate a restart: tear down the tree and build a brand-new
      // controller backed by the same persisted store.
      await tester.pumpWidget(const SizedBox.shrink());

      final secondSession = ThemeController();
      await secondSession.load();

      await tester.pumpWidget(
        _ThemedHarness(controller: secondSession, onContext: (c) => ctx = c),
      );
      await tester.pump();

      // The dark selection is re-applied to the interface, not just the
      // controller field.
      expect(secondSession.themeMode, ThemeMode.dark);
      expect(Theme.of(ctx).brightness, Brightness.dark);
    });

    testWidgets('a first launch with no stored value renders System',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      await controller.load();
      expect(controller.themeMode, ThemeMode.system);

      // With System selected and the OS in light mode, the UI is light.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      late BuildContext ctx;
      await tester.pumpWidget(
        _ThemedHarness(controller: controller, onContext: (c) => ctx = c),
      );
      await tester.pump();

      expect(Theme.of(ctx).brightness, Brightness.light);
    });
  });
}

/// A minimal harness that drives a [MaterialApp] from a [ThemeController] the
/// way the real shell will: light/dark themes plus `themeMode`, rebuilding on
/// every `notifyListeners`. A [Builder] under the app reports its
/// [BuildContext] so a test can read the *resolved* theme via `Theme.of`.
class _ThemedHarness extends StatelessWidget {
  const _ThemedHarness({required this.controller, required this.onContext});

  final ThemeController controller;
  final ValueChanged<BuildContext> onContext;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: QpicTheme.light,
          darkTheme: QpicTheme.dark,
          themeMode: controller.themeMode,
          home: Builder(
            builder: (context) {
              onContext(context);
              return const SizedBox.shrink();
            },
          ),
        );
      },
    );
  }
}
