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
      appBar: AppBar(
        // Brand + tabs live in the title area; Help + theme switcher in actions.
        titleSpacing: 16,
        title: Row(
          children: <Widget>[
            _QpicBrand(palette: palette),
            const SizedBox(width: 24),
            Flexible(
              child: _ToolTabBar(
                selected: _selected,
                enabled: widget.enabled,
                onSelected: _selectTool,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('shell-help-button'),
            tooltip: 'Help',
            icon: const Icon(Icons.help_outline),
            onPressed: widget.enabled ? () => HelpScreen.open(context) : null,
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ThemeSwitcher(controller: widget.themeController),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: IndexedStack(
        key: const ValueKey<String>('shell-tool-stack'),
        index: _selected.index,
        children: <Widget>[
          for (final tool in QpicTool.values) _buildToolView(tool),
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
        Icon(Icons.crop, color: brand, size: 22),
        const SizedBox(width: 8),
        Text(
          'Qpic',
          key: const ValueKey<String>('shell-brand'),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: palette?.appBarText ?? theme.colorScheme.onSurface,
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final tool in QpicTool.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
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
class _ToolTab extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final activeColor = palette?.brand ?? theme.colorScheme.primary;
    final inactiveColor =
        palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return TextButton(
      key: ValueKey<String>('tool-tab-${tool.name}'),
      onPressed: enabled ? onTap : null,
      style: TextButton.styleFrom(
        foregroundColor: active ? activeColor : inactiveColor,
        textStyle: theme.textTheme.titleSmall?.copyWith(
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(tool.label),
          const SizedBox(height: 4),
          // Active-tab underline indicator.
          Container(
            height: 2,
            width: 24,
            decoration: BoxDecoration(
              color: active ? activeColor : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
