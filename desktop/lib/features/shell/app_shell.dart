import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import 'help_screen.dart';
import 'theme_switcher.dart';
import 'tool_placeholder.dart';

/// The four tools the app exposes, in tab order (Requirement 4.2).
///
/// Order is significant: index 0 is Auto Crop, which is the default selected
/// tab on launch (Requirement 4.4).
enum QpicTool {
  autoCrop('Auto Crop'),
  manualCrop('Manual Crop'),
  renameBatch('Rename Batch'),
  tools('Tools');

  const QpicTool(this.label);

  /// Tab label shown in the top app bar.
  final String label;
}

/// Acrobat-style application shell: a top app bar (Qpic brand, the four tool
/// tabs, a Help control, and a segmented Light/Dark/System theme switcher) over
/// an [IndexedStack] that hosts the four tool views (Requirement 4.1–4.4).
///
/// The [IndexedStack] keeps every tool view mounted, so switching tabs hides
/// the others without tearing down their state (Requirement 4.3). The default
/// selected tab is Auto Crop (index 0) (Requirement 4.4).
///
/// The actual tool views are slotted in by later tasks; until then each tab
/// shows a distinct [ToolPlaceholder]. To make the views swappable, the shell
/// accepts an optional [toolViewBuilder]; when omitted it builds placeholders.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.themeController,
    this.toolViewBuilder,
    this.enabled = true,
  });

  /// Controller backing the theme switcher (Requirement 4.5, 4.6).
  final ThemeController themeController;

  /// Optional builder for a tool's view. Later tasks supply the real Auto Crop
  /// form, Manual Crop, Rename Batch, and Tools widgets here; when null the
  /// shell renders a [ToolPlaceholder] for each tool.
  final Widget Function(QpicTool tool)? toolViewBuilder;

  /// When false, the tab bar and Help control are disabled. Task 6.2 uses this
  /// to keep the tool UI inert until the engine reports Ready.
  final bool enabled;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Default selected tab is Auto Crop (index 0) per Requirement 4.4.
  QpicTool _selected = QpicTool.autoCrop;

  void _selectTool(QpicTool tool) {
    if (tool == _selected) return;
    setState(() => _selected = tool);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Scaffold(
      body: Column(
        children: <Widget>[
          // Custom app bar that looks more native/polished.
          _QpicAppBar(
            palette: palette,
            theme: theme,
            selected: _selected,
            enabled: widget.enabled,
            onSelected: _selectTool,
            themeController: widget.themeController,
          ),
          // Tool views below the app bar.
          Expanded(
            child: IndexedStack(
              key: const ValueKey<String>('shell-tool-stack'),
              index: _selected.index,
              children: <Widget>[
                for (final tool in QpicTool.values) _buildToolView(tool),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolView(QpicTool tool) {
    final builder = widget.toolViewBuilder;
    if (builder != null) {
      return builder(tool);
    }
    return ToolPlaceholder(
      key: ValueKey<String>('tool-view-${tool.name}'),
      label: tool.label,
    );
  }
}

/// A polished, native-feeling app bar with brand, tool tabs, and actions.
class _QpicAppBar extends StatelessWidget {
  const _QpicAppBar({
    required this.palette,
    required this.theme,
    required this.selected,
    required this.enabled,
    required this.onSelected,
    required this.themeController,
  });

  final QpicPalette? palette;
  final ThemeData theme;
  final QpicTool selected;
  final bool enabled;
  final ValueChanged<QpicTool> onSelected;
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: palette?.appBar ?? theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: palette?.border ?? theme.dividerColor,
            width: 1,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            _QpicBrand(palette: palette),
            const SizedBox(width: 28),
            // Tool tabs with flexible allocation so they never overlap actions.
            Expanded(
              child: _ToolTabBar(
                selected: selected,
                enabled: enabled,
                onSelected: onSelected,
              ),
            ),
            const SizedBox(width: 12),
            // Right-side actions.
            IconButton(
              key: const ValueKey<String>('shell-help-button'),
              tooltip: 'Help',
              icon: Icon(
                Icons.help_outline,
                size: 20,
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: enabled ? () => HelpScreen.open(context) : null,
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(8),
                minimumSize: const Size(36, 36),
              ),
            ),
            const SizedBox(width: 8),
            ThemeSwitcher(controller: themeController),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// The Qpic wordmark shown at the left of the app bar (Requirement 4.1).
class _QpicBrand extends StatelessWidget {
  const _QpicBrand({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.crop, color: brand, size: 20),
        const SizedBox(width: 7),
        Text(
          'Qpic',
          key: const ValueKey<String>('shell-brand'),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: palette?.appBarText ?? theme.colorScheme.onSurface,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

/// Horizontal row of the four tool tabs (Requirement 4.2, 4.3).
class _ToolTabBar extends StatelessWidget {
  const _ToolTabBar({
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final QpicTool selected;
  final bool enabled;
  final ValueChanged<QpicTool> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Use physics that don't start text selection.
      physics: const ClampingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final tool in QpicTool.values)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _ToolTab(
                tool: tool,
                active: tool == selected,
                enabled: enabled,
                onTap: () => onSelected(tool),
              ),
            ),
        ],
      ),
    );
  }
}

/// A single selectable tool tab. Marks itself active when selected
/// (Requirement 4.3) and exposes a stable key for widget tests.
class _ToolTab extends StatefulWidget {
  const _ToolTab({
    required this.tool,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final QpicTool tool;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_ToolTab> createState() => _ToolTabState();
}

class _ToolTabState extends State<_ToolTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final activeColor = palette?.brand ?? theme.colorScheme.primary;
    final textColor = palette?.appBarText ?? theme.colorScheme.onSurface;
    final inactiveColor = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    final Color fgColor = widget.active
        ? activeColor
        : (_hovered ? textColor : inactiveColor);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: ValueKey<String>('tool-tab-${widget.tool.name}'),
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.active
                ? activeColor.withValues(alpha: 0.08)
                : (_hovered ? (palette?.field ?? Colors.transparent) : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.tool.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: widget.active ? FontWeight.w700 : FontWeight.w500,
                  color: fgColor,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 2,
                width: widget.active ? 18 : 0,
                decoration: BoxDecoration(
                  color: widget.active ? activeColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
