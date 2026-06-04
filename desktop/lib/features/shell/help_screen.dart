import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';

/// In-app Help walkthrough surface (Requirement 19.1, 19.2, 19.5).
///
/// Reproduces the web UI's "How to Use" modal (`#howToBtn` / `#howToModal` in
/// `static/index.html`) as native Flutter. The walkthrough is organized into
/// the same three tabs the web modal uses — an overall guide ("UI & UX of
/// Qpic"), "How to Crop", and "How to Rename Batch" (19.5) — and every step's
/// wording is reproduced verbatim from the web markup so the desktop guidance
/// matches the web app exactly.
///
/// The web modal pairs each tab with an embedded YouTube video. Those embeds
/// are external links, so they are intentionally omitted here: the in-app Help
/// contains the step content only, with no external links (19.2).
///
/// Opened from the shell's Help control (task 6.1 / 19.1) via [open].
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key, this.initialTab = 0});

  /// Which tab to show initially (0-indexed into [_helpTabs]).
  final int initialTab;

  /// Opens the Help walkthrough as a modal dialog over the current surface.
  ///
  /// The shell's Help control depends only on "open Help", so this entry point
  /// keeps the same signature the shell already wires up.
  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const HelpScreen(),
    );
  }

  /// Opens the Help walkthrough directly on the Privacy tab.
  static Future<void> openPrivacy(BuildContext context) {
    // Privacy is the last tab.
    final privacyIndex = _helpTabs.indexWhere((t) => t.id == 'privacy');
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => HelpScreen(
        initialTab: privacyIndex >= 0 ? privacyIndex : 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: palette?.panel ?? theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      child: DefaultTabController(
        length: _helpTabs.length,
        initialIndex: initialTab.clamp(0, _helpTabs.length - 1),
        child: ConstrainedBox(
          // Mirrors the web modal's max width and tall-but-bounded height.
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _HelpHeader(palette: palette),
              _HelpTabBar(palette: palette),
              Divider(
                height: 1,
                thickness: 1,
                color: palette?.border ?? theme.dividerColor,
              ),
              Flexible(
                child: TabBarView(
                  children: <Widget>[
                    for (final tab in _helpTabs)
                      _HelpTabPanel(
                        key: ValueKey<String>('help-panel-${tab.id}'),
                        tab: tab,
                        palette: palette,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header row reproducing the web modal's title block plus a Close action.
class _HelpHeader extends StatelessWidget {
  const _HelpHeader({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final titleColor = palette?.text ?? theme.colorScheme.onSurface;
    final subColor = palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: brand.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.play_circle_outline, size: 18, color: brand),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'How to Use Qpic',
                  key: const ValueKey<String>('help-title'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Follow the steps below',
                  style: theme.textTheme.bodySmall?.copyWith(color: subColor),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('help-close-button'),
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Tab strip mirroring the web modal's "Tutorial sections" tablist.
class _HelpTabBar extends StatelessWidget {
  const _HelpTabBar({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelColor: brand,
      unselectedLabelColor: muted,
      indicatorColor: brand,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelStyle: theme.textTheme.titleSmall,
      tabs: <Widget>[
        for (final tab in _helpTabs)
          Tab(
            key: ValueKey<String>('help-tab-${tab.id}'),
            text: tab.title,
          ),
      ],
    );
  }
}

/// Scrollable body of a single tab: a section heading followed by the numbered
/// steps, reproducing the web modal's `.how-to-steps` layout.
class _HelpTabPanel extends StatelessWidget {
  const _HelpTabPanel({
    super.key,
    required this.tab,
    required this.palette,
  });

  final _HelpTab tab;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingColor = palette?.text ?? theme.colorScheme.onSurface;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: <Widget>[
        Text(
          tab.heading,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: headingColor,
          ),
        ),
        const SizedBox(height: 12),
        for (final step in tab.steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _HelpStepTile(step: step, palette: palette),
          ),
      ],
    );
  }
}

/// A single numbered step: the circled number, a bold title, and the detail
/// text — mirroring the web `.ht-step` / `.ht-step-num` / `.ht-step-text` rows.
class _HelpStepTile extends StatelessWidget {
  const _HelpStepTile({required this.step, required this.palette});

  final _HelpStep step;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final titleColor = palette?.text ?? theme.colorScheme.onSurface;
    final bodyColor = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: brand.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${step.number}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: brand,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                step.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                step.detail,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: bodyColor,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Walkthrough content
//
// Reproduced verbatim from the "How to Use" modal in `static/index.html`
// (HTML entities decoded to their literal characters; video embeds omitted as
// they are external links). Kept as immutable data so the rendering widgets
// above stay declarative and the content is easy to keep in sync with the web.
// ---------------------------------------------------------------------------

/// One numbered step within a Help tab.
@immutable
class _HelpStep {
  const _HelpStep({
    required this.number,
    required this.title,
    required this.detail,
  });

  final int number;
  final String title;
  final String detail;
}

/// One Help tab: a tablist label, a section heading, and its ordered steps.
@immutable
class _HelpTab {
  const _HelpTab({
    required this.id,
    required this.title,
    required this.heading,
    required this.steps,
  });

  /// Stable identifier used for widget keys (matches the web `data-ht-tab`).
  final String id;

  /// Tab label shown in the tablist.
  final String title;

  /// Section heading shown at the top of the panel.
  final String heading;

  /// Ordered steps for this tab.
  final List<_HelpStep> steps;
}

/// The three walkthrough tabs, in the same order as the web modal (19.5).
const List<_HelpTab> _helpTabs = <_HelpTab>[
  _HelpTab(
    id: 'uiux',
    title: 'UI & UX of Qpic',
    heading: 'Overview',
    steps: <_HelpStep>[
      _HelpStep(
        number: 1,
        title: 'App bar',
        detail: 'Switch between Crop and Rename Batch tools. Use the theme '
            'switcher (light / dark / system) on the right.',
      ),
      _HelpStep(
        number: 2,
        title: 'Left panel — What to Crop',
        detail: 'Toggle Questions / Solutions, set page ranges, enable Smart '
            'mode and Online AI mode.',
      ),
      _HelpStep(
        number: 3,
        title: 'Right panel — Output Options',
        detail: 'Choose format (PNG/JPEG), DPI, file prefix, and start number '
            'for the exported images.',
      ),
      _HelpStep(
        number: 4,
        title: 'Light & Dark themes',
        detail: 'The app follows your OS preference by default. Override it '
            'anytime with the theme switcher in the top-right corner.',
      ),
    ],
  ),
  _HelpTab(
    id: 'crop',
    title: 'How to Crop',
    heading: 'Cropping Questions',
    steps: <_HelpStep>[
      _HelpStep(
        number: 1,
        title: 'Upload your PDF',
        detail: 'Click "Choose PDF" or drag-and-drop your MCQ question paper '
            'onto the upload area.',
      ),
      _HelpStep(
        number: 2,
        title: 'Set options',
        detail: 'Choose question numbering style, toggle Smart mode '
            '(auto-detect layout), and enable Online AI mode if you have an '
            'API key.',
      ),
      _HelpStep(
        number: 3,
        title: 'Analyze & Review',
        detail: 'Click "Analyze & Review". Detected question boxes appear over '
            'the page. Fix any wrong boxes by clicking Fix → drag the correct '
            'region.',
      ),
      _HelpStep(
        number: 4,
        title: 'Finalize & Download',
        detail: 'Click "Finalize & Download" to get a ZIP of cropped images. '
            'Choose Combined, Questions only, or Solutions only.',
      ),
    ],
  ),
  _HelpTab(
    id: 'rename',
    title: 'How to Rename Batch',
    heading: 'Batch Renaming Images',
    steps: <_HelpStep>[
      _HelpStep(
        number: 1,
        title: 'Switch to Rename Batch tab',
        detail: 'Click "Rename Batch" in the top app bar to open the rename '
            'tool.',
      ),
      _HelpStep(
        number: 2,
        title: 'Upload images',
        detail: 'Drag-and-drop or select multiple image files (PNG, JPEG, '
            'etc.) you want to rename.',
      ),
      _HelpStep(
        number: 3,
        title: 'Set a naming pattern',
        detail: 'Type a prefix (e.g. "Q") and set the start number. Use the '
            'Variables button to insert dynamic tokens like {n} for '
            'auto-numbering.',
      ),
      _HelpStep(
        number: 4,
        title: 'Rename & Download ZIP',
        detail: 'Preview the new names in the gallery, remove any unwanted '
            'files, then click "Rename & Download ZIP".',
      ),
    ],
  ),
  _HelpTab(
    id: 'privacy',
    title: 'Privacy',
    heading: 'Your Privacy Matters',
    steps: <_HelpStep>[
      _HelpStep(
        number: 1,
        title: '100% Local Execution',
        detail: 'Qpic runs entirely on your machine. All PDF extraction, '
            'cropping, and image renaming happens locally on your processor '
            'without remote servers.',
      ),
      _HelpStep(
        number: 2,
        title: 'Zero Telemetry & Analytics',
        detail: 'We do not collect, store, or transmit any of your data. '
            'Your files never leave your computer, and there are absolutely '
            'no tracking scripts or analytics.',
      ),
      _HelpStep(
        number: 3,
        title: 'Offline Machine Learning',
        detail: 'The built-in intelligence (YOLOv8 layout detection) is '
            'fully self-contained, performing high-fidelity local model '
            'inference entirely offline.',
      ),
      _HelpStep(
        number: 4,
        title: 'Secure File System Handling',
        detail: 'Your documents and exported cropped images remain strictly '
            'within your local file system, protected under standard system '
            'permissions.',
      ),
      _HelpStep(
        number: 5,
        title: 'Open & Transparent',
        detail: 'Qpic is built with transparency in mind. Your trust is '
            'our priority — we will always keep you informed about any '
            'changes to how the app handles your data.',
      ),
    ],
  ),
];
