import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme_controller.dart';
import 'app_credit.dart';

/// A custom, highly-polished About Qpic dialog featuring a brand logo
/// and a dedicated Privacy tab to assure users that their data is processed 100% locally.
class QpicAboutDialog extends StatefulWidget {
  const QpicAboutDialog({super.key});

  /// Shows the custom about dialog.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const QpicAboutDialog(),
    );
  }

  @override
  State<QpicAboutDialog> createState() => _QpicAboutDialogState();
}

class _QpicAboutDialogState extends State<QpicAboutDialog> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final TapGestureRecognizer _tapRecognizer;
  bool _creditHovered = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 420),
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
                  _buildAppInfoTab(context, palette, theme, brand, brandMagenta, titleColor, muted),
                  _buildPrivacyTab(context, palette, theme, brand, titleColor, muted),
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
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[brand, brandMagenta],
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: brand.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(Icons.crop_rounded, color: Colors.white, size: 38),
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
            'A lightning-fast native desktop client for cropping, organizing, and batch renaming question papers and images.',
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
          description: 'All PDF processing, question cropping, and image renaming occurs entirely on your own computer.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.cloud_off_rounded,
          title: 'No Cloud Uploads',
          description: 'Your documents and files never leave your computer. There are no server uploads or external data storage.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme,
          palette,
          icon: Icons.block_rounded,
          title: 'No Tracking or Telemetry',
          description: 'The application contains absolutely zero tracking, analytics, or telemetry code. Your usage remains fully private.',
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
