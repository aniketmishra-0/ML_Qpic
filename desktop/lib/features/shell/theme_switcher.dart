import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';

/// Segmented Light / Dark / System theme switcher (Requirement 4.5, 4.6).
///
/// Renders three options as a [SegmentedButton] bound to a [ThemeController].
/// Selecting an option calls [ThemeController.setThemeMode], which notifies the
/// shell so `MaterialApp` re-themes without a restart (4.6) and persists the
/// choice for next launch (4.8). System mode tracking is handled by
/// `MaterialApp(themeMode: system)` itself (4.7).
class ThemeSwitcher extends StatelessWidget {
  const ThemeSwitcher({
    super.key,
    required this.controller,
  });

  /// The shared controller whose [ThemeMode] this switcher reads and updates.
  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the selected mode changes so the highlighted segment
    // stays in sync with the controller (including external changes).
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: const <ButtonSegment<ThemeMode>>[
            ButtonSegment<ThemeMode>(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Light'),
              tooltip: 'Light theme',
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Dark'),
              tooltip: 'Dark theme',
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('System'),
              tooltip: 'Follow the operating system',
            ),
          ],
          selected: <ThemeMode>{controller.themeMode},
          onSelectionChanged: (selection) {
            // SegmentedButton (single-select) always emits exactly one value.
            controller.setThemeMode(selection.first);
          },
        );
      },
    );
  }
}
