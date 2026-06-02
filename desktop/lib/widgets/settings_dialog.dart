import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme_controller.dart';
import '../core/sidecar_bootstrap.dart';
import '../core/sidecar_manager.dart';

/// A premium, beautiful Settings Dialog for the Qpic desktop application.
///
/// Features a vertical layout grouped by category (Theme, Default Crop Settings,
/// Naming Conventions, Backend Engine Status), built on top of [QpicPalette] and
/// fully reactive.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.themeController,
    this.sidecarBootstrap,
  });

  final ThemeController themeController;
  final SidecarBootstrap? sidecarBootstrap;

  /// Utility to show this dialog.
  static Future<void> show(
    BuildContext context,
    ThemeController themeController, {
    SidecarBootstrap? sidecarBootstrap,
  }) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => SettingsDialog(
        themeController: themeController,
        sidecarBootstrap: sidecarBootstrap,
      ),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _qPrefixController;
  late final TextEditingController _sPrefixController;

  @override
  void initState() {
    super.initState();
    _qPrefixController = TextEditingController(
      text: widget.themeController.defaultQuestionPrefix,
    );
    _sPrefixController = TextEditingController(
      text: widget.themeController.defaultSolutionPrefix,
    );
  }

  @override
  void dispose() {
    _qPrefixController.dispose();
    _sPrefixController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    return Dialog(
      backgroundColor: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: AnimatedBuilder(
          animation: widget.themeController,
          builder: (context, _) {
            // Keep text fields in sync if they changed externally (e.g. on reset).
            if (_qPrefixController.text != widget.themeController.defaultQuestionPrefix) {
              _qPrefixController.text = widget.themeController.defaultQuestionPrefix;
            }
            if (_sPrefixController.text != widget.themeController.defaultSolutionPrefix) {
              _sPrefixController.text = widget.themeController.defaultSolutionPrefix;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Header Block
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  child: Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: brand.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.settings_outlined, color: brand, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Settings',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: text,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Customize your workspace preferences',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        color: muted,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(color: border, height: 1),

                // Scrollable Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // Category: Theme Selector
                        _CategoryHeader(title: 'THEME', palette: palette),
                        const SizedBox(height: 10),
                        _buildThemeSelector(context, palette),
                        const SizedBox(height: 24),

                        // Category: Default Tool Config
                        _CategoryHeader(title: 'DEFAULT TOOL CONFIG', palette: palette),
                        const SizedBox(height: 14),
                        _buildDpiConfig(context, palette),
                        const SizedBox(height: 16),
                        _buildPaddingConfig(context, palette),
                        const SizedBox(height: 24),

                        // Category: Output & Naming
                        _CategoryHeader(title: 'OUTPUT & NAMING', palette: palette),
                        const SizedBox(height: 14),
                        _buildNamingConfig(context, palette),
                        const SizedBox(height: 16),
                        _buildImageFormatConfig(context, palette),
                        const SizedBox(height: 16),
                        _buildSmartModeConfig(context, palette),
                        const SizedBox(height: 24),

                        // Category: Backend Sidecar Status
                        if (widget.sidecarBootstrap != null) ...<Widget>[
                          _CategoryHeader(title: 'ENGINE STATUS', palette: palette),
                          const SizedBox(height: 12),
                          _buildEngineStatusCard(context, palette),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                ),

                Divider(color: border, height: 1),

                // Actions Bottom Bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      TextButton.icon(
                        icon: const Icon(Icons.restore_rounded, size: 16),
                        label: const Text('Reset to Defaults'),
                        style: TextButton.styleFrom(
                          foregroundColor: palette?.danger ?? theme.colorScheme.error,
                        ),
                        onPressed: () => _confirmReset(context, palette),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // --- Theme selector ---
  Widget _buildThemeSelector(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final currentTheme = widget.themeController.themeMode;
    final activeBg = palette?.field ?? theme.colorScheme.surfaceContainerHighest;
    final borderColor = palette?.border ?? theme.dividerColor;

    return Container(
      decoration: BoxDecoration(
        color: activeBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _ThemeOptionCard(
              mode: ThemeMode.light,
              label: 'Light',
              icon: Icons.light_mode_outlined,
              active: currentTheme == ThemeMode.light,
              palette: palette,
              onTap: () => widget.themeController.setThemeMode(ThemeMode.light),
            ),
          ),
          Expanded(
            child: _ThemeOptionCard(
              mode: ThemeMode.dark,
              label: 'Dark',
              icon: Icons.dark_mode_outlined,
              active: currentTheme == ThemeMode.dark,
              palette: palette,
              onTap: () => widget.themeController.setThemeMode(ThemeMode.dark),
            ),
          ),
          Expanded(
            child: _ThemeOptionCard(
              mode: ThemeMode.system,
              label: 'System',
              icon: Icons.brightness_auto_outlined,
              active: currentTheme == ThemeMode.system,
              palette: palette,
              onTap: () => widget.themeController.setThemeMode(ThemeMode.system),
            ),
          ),
        ],
      ),
    );
  }

  // --- DPI Config Slider ---
  Widget _buildDpiConfig(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final int dpi = widget.themeController.defaultDpi;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Default DPI',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
                ),
                Text('Render density for PDF processing', style: TextStyle(fontSize: 11, color: muted)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: palette?.field ?? theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: palette?.borderSoft ?? theme.dividerColor),
              ),
              child: Text(
                '$dpi DPI',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Slider(
          value: dpi.toDouble(),
          min: 72,
          max: 600,
          divisions: 528,
          onChanged: (val) => widget.themeController.setDefaultDpi(val.round()),
        ),
      ],
    );
  }

  // --- Padding Config Slider ---
  Widget _buildPaddingConfig(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final int padding = widget.themeController.defaultPadding;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Default Padding',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
                ),
                Text('Extra pixel margin surrounding crops', style: TextStyle(fontSize: 11, color: muted)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: palette?.field ?? theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: palette?.borderSoft ?? theme.dividerColor),
              ),
              child: Text(
                '$padding px',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Slider(
          value: padding.toDouble(),
          min: 0,
          max: 200,
          divisions: 200,
          onChanged: (val) => widget.themeController.setDefaultPadding(val.round()),
        ),
      ],
    );
  }

  // --- Naming inputs ---
  Widget _buildNamingConfig(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Filename Prefixes',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
        ),
        const SizedBox(height: 2),
        Text('Default naming prefixes for Questions and Solutions', style: TextStyle(fontSize: 11, color: muted)),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _qPrefixController,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: 'Question Prefix',
                  hintText: 'e.g. Q',
                  isDense: true,
                  counterText: '',
                ),
                inputFormatters: [
                  LengthLimitingTextInputFormatter(10),
                ],
                onChanged: (val) => widget.themeController.setDefaultQuestionPrefix(val),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: TextField(
                controller: _sPrefixController,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: 'Solution Prefix',
                  hintText: 'e.g. S',
                  isDense: true,
                  counterText: '',
                ),
                inputFormatters: [
                  LengthLimitingTextInputFormatter(10),
                ],
                onChanged: (val) => widget.themeController.setDefaultSolutionPrefix(val),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- Format segmented button ---
  Widget _buildImageFormatConfig(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final currentFormat = widget.themeController.defaultImageFormat;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Default Output Format',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
            ),
            Text('Default format for exported images', style: TextStyle(fontSize: 11, color: muted)),
          ],
        ),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'png', label: Text('PNG')),
            ButtonSegment<String>(value: 'jpg', label: Text('JPG')),
          ],
          selected: <String>{currentFormat},
          onSelectionChanged: (val) {
            if (val.isNotEmpty) {
              widget.themeController.setDefaultImageFormat(val.first);
            }
          },
        ),
      ],
    );
  }

  // --- Smart Mode switcher ---
  Widget _buildSmartModeConfig(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final isSmart = widget.themeController.defaultSmartMode;

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'Default Smart Mode',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
      ),
      subtitle: Text(
        'Enable review canvas step by default',
        style: TextStyle(fontSize: 11, color: muted),
      ),
      value: isSmart,
      onChanged: (val) => widget.themeController.setDefaultSmartMode(val),
    );
  }

  // --- Sidecar Backend Engine Card ---
  Widget _buildEngineStatusCard(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final bootstrap = widget.sidecarBootstrap!;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    return StreamBuilder<SidecarStatus>(
      stream: bootstrap.status,
      initialData: bootstrap.currentStatus,
      builder: (context, snapshot) {
        final status = snapshot.data ?? SidecarStatus.stopped;
        final isReady = status == SidecarStatus.ready;

        // Visual properties based on status
        Color badgeColor;
        String badgeText;
        switch (status) {
          case SidecarStatus.ready:
            badgeColor = palette?.success ?? theme.colorScheme.primary;
            badgeText = 'Connected';
            break;
          case SidecarStatus.starting:
          case SidecarStatus.selectingPort:
          case SidecarStatus.waitingHealth:
            badgeColor = palette?.warn ?? Colors.orange;
            badgeText = 'Starting...';
            break;
          case SidecarStatus.failed:
          case SidecarStatus.stopped:
          case SidecarStatus.engineStopped:
            badgeColor = palette?.danger ?? theme.colorScheme.error;
            badgeText = status == SidecarStatus.failed ? 'Failed' : 'Stopped';
            break;
        }

        return Container(
          decoration: BoxDecoration(
            color: palette?.panelAlt ?? theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    'Local Processing Engine',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: badgeColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    'Server Endpoint',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                  Text(
                    isReady ? bootstrap.baseUrl.toString() : 'Offline',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Courier',
                      fontWeight: FontWeight.bold,
                      color: isReady ? text : muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Confirm Reset dialog ---
  void _confirmReset(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: palette?.panel ?? theme.colorScheme.surface,
          title: const Text('Reset Settings?'),
          content: const Text(
            'This will clear all custom default configurations and restore factory values. This action cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: palette?.danger ?? theme.colorScheme.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                widget.themeController.resetToDefaults();
                // Reset the inputs
                _qPrefixController.text = 'Q';
                _sPrefixController.text = 'S';
                Navigator.of(context).pop();
              },
              child: const Text('Reset'),
            ),
          ],
        );
      },
    );
  }
}

// --- Small visual helper elements ---

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.title,
    required this.palette,
  });

  final String title;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        color: palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _ThemeOptionCard extends StatelessWidget {
  const _ThemeOptionCard({
    required this.mode,
    required this.label,
    required this.icon,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final IconData icon;
  final bool active;
  final QpicPalette? palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final activeBg = palette?.panel ?? theme.colorScheme.surface;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? brand.withValues(alpha: 0.5) : Colors.transparent,
          ),
          boxShadow: active
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: active ? brand : muted,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.bold : FontWeight.w500,
                color: active ? text : muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
