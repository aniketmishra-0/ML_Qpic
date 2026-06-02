import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeController persistence (Req 4.8, 4.9)', () {
    test('defaults to system on first launch with no stored value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();

      // Default before load.
      expect(controller.themeMode, ThemeMode.system);

      await controller.load();
      expect(controller.themeMode, ThemeMode.system);
    });

    test('re-applies a stored value on launch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ThemeController.storageKey: 'dark',
      });
      final controller = ThemeController();

      await controller.load();
      expect(controller.themeMode, ThemeMode.dark);
    });

    test('falls back to system when the stored value is unrecognized',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ThemeController.storageKey: 'midnight',
      });
      final controller = ThemeController();

      await controller.load();
      expect(controller.themeMode, ThemeMode.system);
    });

    test('setThemeMode persists the selection and notifies listeners',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setThemeMode(ThemeMode.light);
      expect(controller.themeMode, ThemeMode.light);
      expect(notifications, 1);

      // The choice survives a fresh controller backed by the same store.
      final reloaded = ThemeController();
      await reloaded.load();
      expect(reloaded.themeMode, ThemeMode.light);
    });

    test('setThemeMode with the current mode does not notify but still persists',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      // Already system by default — no state change, so no notification.
      await controller.setThemeMode(ThemeMode.system);
      expect(notifications, 0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ThemeController.storageKey), 'system');
    });

    test('round-trips every ThemeMode through storage', () async {
      for (final mode in ThemeMode.values) {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final controller = ThemeController();
        await controller.setThemeMode(mode);

        final reloaded = ThemeController();
        await reloaded.load();
        expect(reloaded.themeMode, mode, reason: 'failed for $mode');
      }
    });
  });

  group('ThemeController settings preferences', () {
    test('defaults are returned before loading', () {
      final controller = ThemeController();
      expect(controller.defaultDpi, 200);
      expect(controller.defaultPadding, 20);
      expect(controller.defaultQuestionPrefix, 'Q');
      expect(controller.defaultSolutionPrefix, 'S');
      expect(controller.defaultImageFormat, 'png');
      expect(controller.defaultSmartMode, true);
    });

    test('restores custom preferences from storage', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ThemeController.dpiKey: 300,
        ThemeController.paddingKey: 40,
        ThemeController.questionPrefixKey: 'Quest',
        ThemeController.solutionPrefixKey: 'Sol',
        ThemeController.imageFormatKey: 'jpg',
        ThemeController.smartModeKey: false,
      });
      final controller = ThemeController();
      await controller.load();

      expect(controller.defaultDpi, 300);
      expect(controller.defaultPadding, 40);
      expect(controller.defaultQuestionPrefix, 'Quest');
      expect(controller.defaultSolutionPrefix, 'Sol');
      expect(controller.defaultImageFormat, 'jpg');
      expect(controller.defaultSmartMode, false);
    });

    test('sets and persists preferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      await controller.setDefaultDpi(150);
      await controller.setDefaultPadding(10);
      await controller.setDefaultQuestionPrefix('A');
      await controller.setDefaultSolutionPrefix('B');
      await controller.setDefaultImageFormat('jpg');
      await controller.setDefaultSmartMode(false);

      final reloaded = ThemeController();
      await reloaded.load();

      expect(reloaded.defaultDpi, 150);
      expect(reloaded.defaultPadding, 10);
      expect(reloaded.defaultQuestionPrefix, 'A');
      expect(reloaded.defaultSolutionPrefix, 'B');
      expect(reloaded.defaultImageFormat, 'jpg');
      expect(reloaded.defaultSmartMode, false);
    });

    test('resetToDefaults clears custom preferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = ThemeController();
      await controller.setDefaultDpi(150);
      await controller.setDefaultPadding(10);
      await controller.setDefaultQuestionPrefix('A');
      await controller.setDefaultSolutionPrefix('B');
      await controller.setDefaultImageFormat('jpg');
      await controller.setDefaultSmartMode(false);

      await controller.resetToDefaults();

      expect(controller.defaultDpi, 200);
      expect(controller.defaultPadding, 20);
      expect(controller.defaultQuestionPrefix, 'Q');
      expect(controller.defaultSolutionPrefix, 'S');
      expect(controller.defaultImageFormat, 'png');
      expect(controller.defaultSmartMode, true);

      final reloaded = ThemeController();
      await reloaded.load();
      expect(reloaded.defaultDpi, 200);
      expect(reloaded.defaultPadding, 20);
    });
  });

  group('QpicPalette reproduces web CSS variables (Req 4.5)', () {
    test('dark palette matches the web :root dark block', () {
      const p = QpicPalette.dark;
      // Brand duo-tone (theme-independent).
      expect(p.brand, const Color(0xFF7C6CFF)); // --accent
      expect(p.brandMagenta, const Color(0xFFB14EFF)); // --accent-2
      expect(p.brandBlue, const Color(0xFF4B8DFF)); // --accent-3
      // Status accents used by box outlines + note chips.
      expect(p.success, const Color(0xFF2DD4BF)); // --success
      expect(p.warn, const Color(0xFFFBBF24)); // --warn
      expect(p.danger, const Color(0xFFFB7185)); // --danger
      // A couple of surfaces.
      expect(p.background, const Color(0xFF0C0B15)); // --bg
      expect(p.text, const Color(0xFFF4F3FB)); // --text
    });

    test('light palette matches the web :root[data-theme="light"] block', () {
      const p = QpicPalette.light;
      expect(p.brand, const Color(0xFF7C6CFF)); // --accent (shared)
      expect(p.success, const Color(0xFF0D9488)); // --success
      expect(p.warn, const Color(0xFFD97706)); // --warn
      expect(p.danger, const Color(0xFFE11D48)); // --danger
      expect(p.background, const Color(0xFFF4F3FB)); // --bg
      expect(p.text, const Color(0xFF1B1830)); // --text
    });

    test('derived canvas/note colors map to the right CSS rules', () {
      const p = QpicPalette.dark;
      expect(p.boxOutline, p.success); // .existing-box outline
      expect(p.boxFlagged, p.warn); // .existing-box.flagged
      expect(p.boxEditing, p.brand); // .existing-box.editing
      expect(p.noteGap, p.brand); // .note.gap
      expect(p.noteIncomplete, p.danger); // .note.incomplete
      expect(p.noteDefault, p.warn); // default .note (duplicate/tiny/low_conf)
    });

    test('lerp endpoints return the bounding palettes', () {
      const a = QpicPalette.light;
      const b = QpicPalette.dark;
      expect(a.lerp(b, 0).background, a.background);
      expect(a.lerp(b, 1).background, b.background);
    });
  });

  group('QpicTheme carries the palette extension', () {
    test('light theme exposes the light palette', () {
      final theme = QpicTheme.light;
      expect(theme.brightness, Brightness.light);
      final palette = theme.extension<QpicPalette>();
      expect(palette, isNotNull);
      expect(palette!.success, const Color(0xFF0D9488));
    });

    test('dark theme exposes the dark palette', () {
      final theme = QpicTheme.dark;
      expect(theme.brightness, Brightness.dark);
      final palette = theme.extension<QpicPalette>();
      expect(palette, isNotNull);
      expect(palette!.success, const Color(0xFF2DD4BF));
    });
  });
}
