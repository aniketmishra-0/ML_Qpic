import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';

/// Lightweight, stateful stand-in for a tool view.
///
/// The real tool views (Auto Crop form, Manual Crop, Rename Batch, Tools) are
/// implemented in later tasks (9.x, 13.x, 15.x, 16–18). [ToolPlaceholder] lets
/// task 6.1 wire the shell now and gives each tab a *distinct, mutable* surface
/// so the tab-behaviour widget test (task 6.3) can prove that the shell's
/// [IndexedStack] retains each view's state across tab switches.
///
/// It holds a private interaction counter that only changes via the on-screen
/// button. Because [IndexedStack] keeps inactive children mounted, the counter
/// survives switching away to another tab and back (Requirement 4.3).
class ToolPlaceholder extends StatefulWidget {
  const ToolPlaceholder({
    super.key,
    required this.label,
  });

  /// Human-readable name of the tool this placeholder stands in for.
  final String label;

  @override
  State<ToolPlaceholder> createState() => _ToolPlaceholderState();
}

class _ToolPlaceholderState extends State<ToolPlaceholder>
    with AutomaticKeepAliveClientMixin {
  int _interactions = 0;

  // Belt-and-suspenders state retention: IndexedStack already keeps children
  // mounted, but keeping alive guards against future scroll/lazy wrappers.
  @override
  bool get wantKeepAlive => true;

  void _interact() => setState(() => _interactions++);

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            widget.label,
            key: ValueKey<String>('tool-title-${widget.label}'),
            style: theme.textTheme.headlineSmall?.copyWith(
              color: palette?.text ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Coming soon',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Interactions: $_interactions',
            key: ValueKey<String>('tool-counter-${widget.label}'),
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: ValueKey<String>('tool-interact-${widget.label}'),
            onPressed: _interact,
            child: const Text('Interact'),
          ),
        ],
      ),
    );
  }
}
