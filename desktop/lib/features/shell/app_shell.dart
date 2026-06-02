import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import 'app_credit.dart';
import 'help_screen.dart';
import 'theme_switcher.dart';
import 'tool_placeholder.dart';

/// The four tools the app exposes, in navigation order (Requirement 4.2).
///
/// Order is significant: index 0 is Auto Crop, which is the default selected
/// item on launch (Requirement 4.4).
enum QpicTool {
  autoCrop('Auto Crop', Icons.crop_rounded),
  manualCrop('Manual Crop', Icons.crop_free_rounded),
  renameBatch('Rename Batch', Icons.drive_file_rename_outline_rounded),
  tools('Tools', Icons.build_rounded);

  const QpicTool(this.label, this.icon);

  /// Label shown in the navigation rail and elsewhere.
  final String label;

  /// Icon shown in the navigation rail.
  final IconData icon;

  /// Short label used under the rail icon (kept compact for the 72px rail).
  String get shortLabel {
    switch (this) {
      case QpicTool.autoCrop:
        return 'Auto';
      case QpicTool.manualCrop:
        return 'Manual';
      case QpicTool.renameBatch:
        return 'Rename';
      case QpicTool.tools:
        return 'Tools';
    }
  }
}

/// Modern application shell: a left navigation rail (Qpic brand mark, the four
/// tool destinations, a Help control, and a vertical Light/Dark/System theme
/// switcher) beside an [IndexedStack] that hosts the four tool views
/// (Requirement 4.1–4.4).
///
/// The [IndexedStack] keeps every tool view mounted, so switching tools hides
/// the others without tearing down their state (Requirement 4.3). The default
/// selected tool is Auto Crop (index 0) (Requirement 4.4).
///
/// The actual tool views are slotted in by the host via [toolViewBuilder];
/// when omitted the shell renders a distinct [ToolPlaceholder] per tool. The
/// behaviour contract (tab keys, stack key, state retention, default selection)
/// is preserved exactly so existing widget tests keep passing.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.themeController,
    this.toolViewBuilder,
    this.enabled = true,
  });

  /// Controller backing the theme switcher (Requirement 4.5, 4.6).
  final ThemeController themeController;

  /// Optional builder for a tool's view. The host supplies the real Auto Crop
  /// form, Manual Crop, Rename Batch, and Tools widgets here; when null the
  /// shell renders a [ToolPlaceholder] for each tool.
  final Widget Function(QpicTool tool)? toolViewBuilder;

  /// When false, the navigation rail and Help control are disabled. The
  /// startup gate uses this to keep the tool UI inert until the engine reports
  /// Ready.
  final bool enabled;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Default selected tool is Auto Crop (index 0) per Requirement 4.4.
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
      body: Row(
        children: <Widget>[
          // Left navigation rail (brand, tools, help, theme switcher).
          _QpicNavRail(
            palette: palette,
            theme: theme,
            selected: _selected,
            enabled: widget.enabled,
            onSelected: _selectTool,
            themeController: widget.themeController,
          ),
          // Tool views fill the remaining space.
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

/// Left navigation rail with the Qpic brand mark at the top, the four tool
/// destinations, and a Help control + vertical theme switcher pinned to the
/// bottom.
class _QpicNavRail extends StatelessWidget {
  const _QpicNavRail({
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
    final Color railColor = palette?.appBar ?? theme.colorScheme.surface;
    final Color borderColor = palette?.border ?? theme.dividerColor;

    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: railColor,
        border: Border(
          right: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: CustomScrollView(
        physics: const ClampingScrollPhysics(),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 10),
                _QpicBrandMark(palette: palette),
                const SizedBox(height: 12),
                // Tool destinations.
                for (final tool in QpicTool.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: _NavRailItem(
                      tool: tool,
                      active: tool == selected,
                      enabled: enabled,
                      onTap: () => onSelected(tool),
                      palette: palette,
                    ),
                  ),
              ],
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  AppCredit(palette: palette),
                  const SizedBox(height: 16),
                  Container(
                    width: 40,
                    height: 1,
                    color: borderColor,
                  ),
                  const SizedBox(height: 4),
                  // Help control.
                  _NavHelpButton(palette: palette, enabled: enabled),
                  const SizedBox(height: 6),
                  // Vertical theme switcher.
                  ThemeSwitcher(controller: themeController),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Qpic brand mark shown at the top of the rail (Requirement 4.1).
class _QpicBrandMark extends StatelessWidget {
  const _QpicBrandMark({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final brandMagenta = palette?.brandMagenta ?? theme.colorScheme.tertiary;

    return Container(
      key: const ValueKey<String>('shell-brand'),
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: brand.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// A single navigation-rail destination. Marks itself active when selected
/// (Requirement 4.3) and exposes the stable `tool-tab-{name}` key the widget
/// tests drive.
class _NavRailItem extends StatefulWidget {
  const _NavRailItem({
    required this.tool,
    required this.active,
    required this.enabled,
    required this.onTap,
    required this.palette,
  });

  final QpicTool tool;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  final QpicPalette? palette;

  @override
  State<_NavRailItem> createState() => _NavRailItemState();
}

class _NavRailItemState extends State<_NavRailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = widget.palette;
    final activeColor = palette?.brand ?? theme.colorScheme.primary;
    final textColor = palette?.appBarText ?? theme.colorScheme.onSurface;
    final inactiveColor = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final fieldColor = palette?.field ?? theme.colorScheme.surfaceContainerHighest;

    final Color fgColor = widget.active
        ? activeColor
        : (_hovered ? textColor : inactiveColor);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        key: ValueKey<String>('tool-tab-${widget.tool.name}'),
        onTap: widget.enabled ? widget.onTap : null,
        child: Opacity(
          opacity: widget.enabled ? 1.0 : 0.4,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: 60,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: widget.active
                  ? activeColor.withValues(alpha: 0.12)
                  : (_hovered ? fieldColor : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              border: widget.active
                  ? Border.all(color: activeColor.withValues(alpha: 0.5))
                  : Border.all(color: Colors.transparent),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(widget.tool.icon, size: 21, color: fgColor),
                const SizedBox(height: 5),
                Text(
                  widget.tool.shortLabel,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: widget.active ? FontWeight.w700 : FontWeight.w500,
                    color: fgColor,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Help control pinned near the bottom of the rail.
class _NavHelpButton extends StatelessWidget {
  const _NavHelpButton({required this.palette, required this.enabled});

  final QpicPalette? palette;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return IconButton(
      key: const ValueKey<String>('shell-help-button'),
      tooltip: 'Help',
      icon: Icon(Icons.help_outline_rounded, size: 21, color: muted),
      onPressed: enabled ? () => HelpScreen.open(context) : null,
      style: IconButton.styleFrom(
        padding: const EdgeInsets.all(8),
        minimumSize: const Size(40, 40),
      ),
    );
  }
}
