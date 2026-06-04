import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme_controller.dart';
import 'app_credit.dart';

/// A custom, highly-polished About Qpic dialog featuring a brand logo
/// and a dedicated Privacy tab to assure users that their data is processed 100% locally.
class QpicAboutDialog extends StatefulWidget {
  const QpicAboutDialog({
    super.key,
    this.initialTab = 0,
  });

  final int initialTab;

  /// Shows the custom about dialog.
  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => QpicAboutDialog(initialTab: initialTab),
    );
  }

  @override
  State<QpicAboutDialog> createState() => _QpicAboutDialogState();
}

class _QpicAboutDialogState extends State<QpicAboutDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final TapGestureRecognizer _tapRecognizer;
  bool _creditHovered = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
    _tapRecognizer = TapGestureRecognizer()..onTap = _openLinkedIn;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _tapRecognizer.dispose();
    super.dispose();
  }

  Future<void> _openLinkedIn() async {
    await launchUrl(
      AppCredit.linkedInUrl,
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final brandMagenta = palette?.brandMagenta ?? theme.colorScheme.tertiary;
    final titleColor = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: palette?.panel ?? theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Header with Close Button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: <Widget>[
                  Text(
                    'About Qpic',
                    key: const ValueKey<String>('about-dialog-title'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey<String>('about-dialog-close'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Tab Header
            TabBar(
              controller: _tabController,
              labelColor: brand,
              unselectedLabelColor: muted,
              indicatorColor: brand,
              indicatorSize: TabBarIndicatorSize.tab,
              labelStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: theme.textTheme.titleSmall,
              tabs: const <Widget>[
                Tab(
                  key: ValueKey<String>('about-tab-info'),
                  text: 'App Info',
                ),
                Tab(
                  key: ValueKey<String>('about-tab-help'),
                  text: 'How to Use',
                ),
                Tab(
                  key: ValueKey<String>('about-tab-privacy'),
                  text: 'Privacy',
                ),
              ],
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: border,
            ),
            // Tab View Content
            Flexible(
              child: TabBarView(
                controller: _tabController,
                children: <Widget>[
                  _buildAppInfoTab(context, palette, theme, brand, brandMagenta,
                      titleColor, muted),
                  _buildHelpTab(
                      context, palette, theme, brand, titleColor, muted),
                  _buildPrivacyTab(
                      context, palette, theme, brand, titleColor, muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppInfoTab(
    BuildContext context,
    QpicPalette? palette,
    ThemeData theme,
    Color brand,
    Color brandMagenta,
    Color titleColor,
    Color muted,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Large Logo
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: brand.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset(
                'assets/logo.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // App Title
          Text(
            'Qpic',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: titleColor,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          // Version Info
          Text(
            'Version 1.0.0 (1)',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          // Description
          Text(
            'Qpic is an advanced, offline-first native desktop assistant designed for educators and students. Easily crop MCQs/questions, organize files, and run batch renaming operations powered by local machine learning.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: titleColor,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          // Copyright & Author Link
          Text(
            'Copyright © 2026 Qpic. All rights reserved.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 6),
          MouseRegion(
            onEnter: (_) => setState(() => _creditHovered = true),
            onExit: (_) => setState(() => _creditHovered = false),
            child: Text.rich(
              TextSpan(
                children: <TextSpan>[
                  TextSpan(
                    text: 'Developer: ',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  TextSpan(
                    text: 'aniketmishra',
                    recognizer: _tapRecognizer,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _creditHovered ? brand : muted,
                      decoration: _creditHovered
                          ? TextDecoration.underline
                          : TextDecoration.none,
                      decorationColor: brand,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpTab(
    BuildContext context,
    QpicPalette? palette,
    ThemeData theme,
    Color brand,
    Color titleColor,
    Color muted,
  ) {
    final panelAlt = palette?.panelAlt ?? theme.colorScheme.surfaceContainerLow;
    final border = palette?.border ?? theme.dividerColor;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      children: <Widget>[
        // Quick Start
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: panelAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.rocket_launch_rounded, color: brand, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Quick Start',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Load a PDF → Analyze → Review detections → Finalize & Download your cropped question images.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Steps
        _buildHelpStep(theme, palette, number: '1', title: 'Load a PDF',
            description: 'Click "Choose PDF" or drag-and-drop your exam paper onto the upload area.'),
        const SizedBox(height: 14),
        _buildHelpStep(theme, palette, number: '2', title: 'Configure & Analyze',
            description: 'Set question numbering style, enable Smart Mode for the full pipeline with review, and optionally toggle Online mode for AI-assisted detection on tricky layouts. Click "Analyze" to detect questions.'),
        const SizedBox(height: 14),
        _buildHelpStep(theme, palette, number: '3', title: 'Review Detections',
            description: 'The review canvas shows detected boxes over page previews. Fix incorrect boxes with "Re-select", draw new boxes for missed questions, or delete duplicates. Snap-to-content auto-tightens drawn boxes.'),
        const SizedBox(height: 14),
        _buildHelpStep(theme, palette, number: '4', title: 'Finalize & Download',
            description: 'Click "Finalize" to generate crisp cropped images from the original PDF. Download as Combined, Questions-only, or Solutions-only ZIP.'),
        const SizedBox(height: 20),
        Divider(color: border),
        const SizedBox(height: 16),
        // ML Detection
        _buildPrivacyPoint(theme, palette,
            icon: Icons.psychology_rounded,
            title: 'ML Detection',
            description: 'The built-in ML model detects question and solution regions as bounding box coordinates only. It does not read, extract, or understand your document content. All actual cropping is done locally from the original PDF source.'),
        const SizedBox(height: 14),
        _buildPrivacyPoint(theme, palette,
            icon: Icons.cloud_off_rounded,
            title: 'Online AI (Optional)',
            description: 'When enabled, page images are sent to your configured AI provider solely to obtain region coordinates. No document content is extracted or stored. This feature requires an API key and is disabled by default.'),
        const SizedBox(height: 14),
        _buildPrivacyPoint(theme, palette,
            icon: Icons.view_column_rounded,
            title: 'Bilingual PDF Support',
            description: 'Automatically detects side-by-side bilingual layouts and merges duplicate detections. Use the Bilingual Stitcher to choose English only, Hindi only, or stitched bilingual output.'),
      ],
    );
  }

  Widget _buildHelpStep(
    ThemeData theme,
    QpicPalette? palette, {
    required String number,
    required String title,
    required String description,
  }) {
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final titleColor = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: brand,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            number,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyTab(
    BuildContext context,
    QpicPalette? palette,
    ThemeData theme,
    Color brand,
    Color titleColor,
    Color muted,
  ) {
    final panelAlt = palette?.panelAlt ?? theme.colorScheme.surfaceContainerLow;
    final border = palette?.border ?? theme.dividerColor;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      children: <Widget>[
        // Alert/Card stating local nature
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: panelAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.shield_outlined, color: brand, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Your Data Stays Yours',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'We respect your privacy. Qpic does not collect, save, or upload any of your files or personal data.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Points
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.computer_rounded,
          title: '100% Local Processing',
          description:
              'All PDF parsing, question detection, and image cropping run entirely on your device. No files are sent to remote servers unless you explicitly enable Online mode.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.block_rounded,
          title: 'Zero Telemetry & Analytics',
          description:
              'No tracking scripts, cookies, or usage telemetry. We do not monitor your activity, collect analytics, or report any data back to us.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.psychology_rounded,
          title: 'Local ML Detection',
          description:
              'The built-in ML model (YOLOv8/ONNX) runs fully offline. It detects question and solution regions as bounding box coordinates only \u2014 it does not read, extract, or understand your document content.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.cloud_off_rounded,
          title: 'Online AI (Optional)',
          description:
              'When Online mode is enabled, only page images are sent to your configured AI provider (Anthropic or OpenRouter) to obtain question region coordinates. No document content is extracted, stored, or retained by the app or the AI provider.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.storage_rounded,
          title: 'Secure Local File Handling',
          description:
              'Your documents and exported cropped images remain strictly within your local file system. Temporary job files are automatically cleaned up after processing.',
        ),
      ],
    );
  }

  Widget _buildPrivacyPoint(
    ThemeData theme,
    QpicPalette? palette, {
    required IconData icon,
    required String title,
    required String description,
  }) {
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final titleColor = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: brand.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: brand),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
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
