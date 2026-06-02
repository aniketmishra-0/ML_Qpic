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
///
/// Visually the placeholder mirrors the real tool pages (Auto / Manual /
/// Rename): the same full-bleed `28,24` page padding, the same top-left
/// title + subtitle header, and a titled card for its body — so switching to
/// this tab no longer drops the user onto a bare, differently-aligned screen.
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

    // Same page chrome as the real tool views: full-bleed padding, a top-left
    // header (title + subtitle), then the body. This keeps every tab aligned.
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _HeaderBar(label: widget.label, palette: palette),
          const SizedBox(height: 18),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: _ComingSoonCard(
                  palette: palette,
                  interactions: _interactions,
                  onInteract: _interact,
                  label: widget.label,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-left page header (title + subtitle), matching the Auto / Manual / Rename
/// views so every tab opens with the same alignment.
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.label, required this.palette});

  final String label;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          // Preserved key: the shell tab-behaviour tests locate each tab's view
          // by `tool-title-{label}`.
          key: ValueKey<String>('tool-title-$label'),
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: palette?.text ?? theme.colorScheme.onSurface,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'More PDF utilities are on the way.',
          style: TextStyle(
            fontSize: 13.5,
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// The body card. Uses the same titled-card surface (Material + rounded border)
/// as the other tools' section cards so it reads as part of the same app.
class _ComingSoonCard extends StatelessWidget {
  const _ComingSoonCard({
    required this.palette,
    required this.interactions,
    required this.onInteract,
    required this.label,
  });

  final QpicPalette? palette;
  final int interactions;
  final VoidCallback onInteract;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette?.border ?? theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: brand.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.construction_rounded, color: brand, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              'Coming soon',
              style: theme.textTheme.titleMedium?.copyWith(
                color: palette?.text ?? theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'This tool is still being built. Check back in a future update.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Interactions: $interactions',
              key: ValueKey<String>('tool-counter-$label'),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: ValueKey<String>('tool-interact-$label'),
              onPressed: onInteract,
              child: const Text('Interact'),
            ),
          ],
        ),
      ),
    );
  }
}
