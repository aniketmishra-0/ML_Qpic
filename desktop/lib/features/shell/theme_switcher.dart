import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';

/// Compact vertical Light / Dark / System theme switcher (Requirement 4.5, 4.6).
///
/// Renders three icon options stacked in a rounded pill, sized to fit the
/// left navigation rail. Selecting an option calls
/// [ThemeController.setThemeMode], which notifies the shell so `MaterialApp`
/// re-themes without a restart (4.6) and persists the choice for next launch
/// (4.8). System mode tracking is handled by `MaterialApp(themeMode: system)`
/// itself (4.7).
class ThemeSwitcher extends StatelessWidget {
  const ThemeSwitcher({
    super.key,
    required this.controller,
  });

  /// The shared controller whose [ThemeMode] this switcher reads and updates.
  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final fieldColor =
        palette?.field ?? theme.colorScheme.surfaceContainerHighest;
    final borderColor = palette?.borderSoft ?? theme.dividerColor;

    // Rebuild whenever the selected mode changes so the highlighted option
    // stays in sync with the controller (including external changes).
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: fieldColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ThemeOption(
                mode: ThemeMode.light,
                icon: Icons.light_mode_outlined,
                tooltip: 'Light theme',
                selected: controller.themeMode == ThemeMode.light,
                palette: palette,
                onTap: () => controller.setThemeMode(ThemeMode.light),
              ),
              const SizedBox(height: 2),
              _ThemeOption(
                mode: ThemeMode.dark,
                icon: Icons.dark_mode_outlined,
                tooltip: 'Dark theme',
                selected: controller.themeMode == ThemeMode.dark,
                palette: palette,
                onTap: () => controller.setThemeMode(ThemeMode.dark),
              ),
              const SizedBox(height: 2),
              _ThemeOption(
                mode: ThemeMode.system,
                icon: Icons.brightness_auto_outlined,
                tooltip: 'Follow the operating system',
                selected: controller.themeMode == ThemeMode.system,
                palette: palette,
                onTap: () => controller.setThemeMode(ThemeMode.system),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A single theme option button within the vertical switcher pill.
class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.mode,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final ThemeMode mode;
  final IconData icon;
  final String tooltip;
  final bool selected;
  final QpicPalette? palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final selectedBg = palette?.panel ?? theme.colorScheme.surface;

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: selected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 15,
            color: selected ? brand : muted,
          ),
        ),
      ),
    );
  }
}
