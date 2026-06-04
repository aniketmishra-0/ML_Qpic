import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:file_selector/file_selector.dart' show XTypeGroup;

import '../core/api_client.dart';
import '../models/crop.dart';
import '../core/sidecar_bootstrap.dart';
import '../core/sidecar_manager.dart';
import '../core/theme_controller.dart';
import '../features/shell/about_dialog.dart';
import 'qpic_dropdown.dart';

enum SettingsTab {
  general,
  naming,
  mlModel,
  about,
  privacy,
}

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

  bool _loadingML = false;
  bool _updatingML = false;
  String? _mlError;

  final _modelPathController = TextEditingController();
  final _labelsPathController = TextEditingController();
  final _modelNameController = TextEditingController();
  double _confidence = 0.35;
  int _inputSize = 640;
  bool _localMlAvailable = false;

  SettingsTab _activeTab = SettingsTab.general;

  @override
  void initState() {
    super.initState();
    _qPrefixController = TextEditingController(
      text: widget.themeController.defaultQuestionPrefix,
    );
    _sPrefixController = TextEditingController(
      text: widget.themeController.defaultSolutionPrefix,
    );
    _loadMLConfig();
  }

  @override
  void dispose() {
    _qPrefixController.dispose();
    _sPrefixController.dispose();
    _modelPathController.dispose();
    _labelsPathController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  Future<void> _loadMLConfig() async {
    final bootstrap = widget.sidecarBootstrap;
    if (bootstrap == null || bootstrap.currentStatus != SidecarStatus.ready) {
      return;
    }
    final url = bootstrap.baseUrl;
    if (url == null) return;

    setState(() {
      _loadingML = true;
      _mlError = null;
    });

    try {
      final client = ApiClient(url);
      final config = await client.getMlConfig();
      setState(() {
        _modelPathController.text = config.modelPath ?? '';
        _labelsPathController.text = config.labelsPath ?? '';
        _modelNameController.text = config.modelName;
        _confidence = config.confidence;
        _inputSize = config.inputSize;
        _localMlAvailable = config.localMlAvailable;
        _loadingML = false;
      });
    } catch (e) {
      setState(() {
        _mlError = e.toString();
        _loadingML = false;
      });
    }
  }

  Future<void> _saveMLConfig() async {
    final bootstrap = widget.sidecarBootstrap;
    if (bootstrap == null || bootstrap.currentStatus != SidecarStatus.ready) {
      return;
    }
    final url = bootstrap.baseUrl;
    if (url == null) return;

    setState(() {
      _updatingML = true;
      _mlError = null;
    });

    try {
      final client = ApiClient(url);
      final config = await client.updateMlConfig(
        modelPath: _modelPathController.text.trim().isEmpty
            ? ''
            : _modelPathController.text.trim(),
        labelsPath: _labelsPathController.text.trim().isEmpty
            ? ''
            : _labelsPathController.text.trim(),
        modelName: _modelNameController.text.trim(),
        confidence: _confidence,
        inputSize: _inputSize,
      );
      setState(() {
        _modelPathController.text = config.modelPath ?? '';
        _labelsPathController.text = config.labelsPath ?? '';
        _modelNameController.text = config.modelName;
        _confidence = config.confidence;
        _inputSize = config.inputSize;
        _localMlAvailable = config.localMlAvailable;
        _updatingML = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ML Model Configuration updated successfully!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _mlError = e.toString();
        _updatingML = false;
      });
    }
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
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border, width: 1.0),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 600),
        child: AnimatedBuilder(
          animation: widget.themeController,
          builder: (context, _) {
            // Keep text fields in sync if they changed externally (e.g. on reset).
            if (_qPrefixController.text !=
                widget.themeController.defaultQuestionPrefix) {
              _qPrefixController.text =
                  widget.themeController.defaultQuestionPrefix;
            }
            if (_sPrefixController.text !=
                widget.themeController.defaultSolutionPrefix) {
              _sPrefixController.text =
                  widget.themeController.defaultSolutionPrefix;
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
                          color: brand.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.settings_outlined,
                            color: brand, size: 22),
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

                // Side-by-side split screen
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // Left Sidebar Navigation
                      Container(
                        width: 210,
                        decoration: BoxDecoration(
                          color: palette?.backgroundAlt ??
                              theme.colorScheme.surfaceContainerLow,
                          border: Border(right: BorderSide(color: border)),
                        ),
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 8),
                          children: _buildSidebarItems(context, palette),
                        ),
                      ),

                      // Right Content Panel
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _buildActiveTabContent(context, palette),
                        ),
                      ),
                    ],
                  ),
                ),

                Divider(color: border, height: 1),

                // Actions Bottom Bar
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      TextButton.icon(
                        icon: const Icon(Icons.restore_rounded, size: 16),
                        label: const Text('Reset to Defaults'),
                        style: TextButton.styleFrom(
                          foregroundColor:
                              palette?.danger ?? theme.colorScheme.error,
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

  Widget _buildMlModelConfig(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    if (_loadingML) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_mlError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Text(
              'Error loading ML configuration: $_mlError',
              style: TextStyle(
                  color: palette?.danger ?? theme.colorScheme.error,
                  fontSize: 12),
            ),
          ),

        // Status Card
        Container(
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
                    'Local ML Model Status',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold, color: text),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _localMlAvailable
                          ? (palette?.success ?? Colors.green)
                              .withValues(alpha: 0.15)
                          : (palette?.danger ?? Colors.red)
                              .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _localMlAvailable
                            ? (palette?.success ?? Colors.green)
                                .withValues(alpha: 0.4)
                            : (palette?.danger ?? Colors.red)
                                .withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      _localMlAvailable ? 'Available' : 'Unavailable',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _localMlAvailable
                            ? (palette?.success ?? Colors.green)
                            : (palette?.danger ?? Colors.red),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Model Name Textfield
        TextField(
          controller: _modelNameController,
          decoration: const InputDecoration(
            labelText: 'Model Name',
            hintText: 'e.g. qpic-local-question-detector',
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),

        // Model Path Textfield + Picker
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _modelPathController,
                decoration: const InputDecoration(
                  labelText: 'Model Path (.onnx / .pt)',
                  hintText: 'vendor/models/.../model.onnx',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: () async {
                final file = await fs.openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: 'ONNX/PyTorch Model',
                      extensions: ['onnx', 'pt'],
                    )
                  ],
                );
                if (file != null) {
                  setState(() {
                    _modelPathController.text = file.path;
                  });
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Labels Path Textfield + Picker
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _labelsPathController,
                decoration: const InputDecoration(
                  labelText: 'Labels Path (.json)',
                  hintText: 'vendor/models/.../labels.json',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: () async {
                final file = await fs.openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: 'JSON Labels',
                      extensions: ['json'],
                    )
                  ],
                );
                if (file != null) {
                  setState(() {
                    _labelsPathController.text = file.path;
                  });
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Confidence Slider
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  'Default ML Confidence',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold, color: text),
                ),
                Text(
                  _confidence.toStringAsFixed(2),
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold, color: text),
                ),
              ],
            ),
            Slider(
              value: _confidence,
              min: 0.0,
              max: 1.0,
              divisions: 100,
              onChanged: (val) => setState(() => _confidence = val),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Input Size Dropdown
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              'Model Input Size',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: text),
            ),
            QpicDropdownButton<int>(
              value: _inputSize,
              items: [320, 416, 512, 640, 800, 1024].map((size) {
                return QpicDropdownItem<int>(
                  value: size,
                  label: '$size px',
                );
              }).toList(),
              onChanged: (val) {
                setState(() => _inputSize = val);
              },
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Save Button
        Align(
          alignment: Alignment.centerRight,
          child: _updatingML
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : FilledButton.icon(
                  icon: const Icon(Icons.save_rounded, size: 16),
                  label: const Text('Apply ML Settings'),
                  onPressed: _saveMLConfig,
                ),
        ),
      ],
    );
  }

  // --- Theme selector ---
  Widget _buildThemeSelector(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final currentTheme = widget.themeController.themeMode;
    final activeBg =
        palette?.field ?? theme.colorScheme.surfaceContainerHighest;
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
              onTap: () =>
                  widget.themeController.setThemeMode(ThemeMode.system),
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
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: text),
                ),
                Text('Render density for PDF processing',
                    style: TextStyle(fontSize: 11, color: muted)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color:
                    palette?.field ?? theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: palette?.borderSoft ?? theme.dividerColor),
              ),
              child: Text(
                '$dpi DPI',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: text),
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
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: text),
                ),
                Text('Extra pixel margin surrounding crops',
                    style: TextStyle(fontSize: 11, color: muted)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color:
                    palette?.field ?? theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: palette?.borderSoft ?? theme.dividerColor),
              ),
              child: Text(
                '$padding px',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: text),
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
          onChanged: (val) =>
              widget.themeController.setDefaultPadding(val.round()),
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
          style:
              TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
        ),
        const SizedBox(height: 2),
        Text('Default naming prefixes for Questions and Solutions',
            style: TextStyle(fontSize: 11, color: muted)),
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
                onChanged: (val) =>
                    widget.themeController.setDefaultQuestionPrefix(val),
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
                onChanged: (val) =>
                    widget.themeController.setDefaultSolutionPrefix(val),
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
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold, color: text),
            ),
            Text('Default format for exported images',
                style: TextStyle(fontSize: 11, color: muted)),
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
        style:
            TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: text),
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
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold, color: text),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border:
                          Border.all(color: badgeColor.withValues(alpha: 0.4)),
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

  List<Widget> _buildSidebarItems(BuildContext context, QpicPalette? palette) {
    final hasML = widget.sidecarBootstrap != null;
    return <Widget>[
      _buildSidebarTile(
        tab: SettingsTab.general,
        label: 'General Config',
        icon: Icons.tune_rounded,
        palette: palette,
      ),
      _buildSidebarTile(
        tab: SettingsTab.naming,
        label: 'Output & Naming',
        icon: Icons.edit_note_rounded,
        palette: palette,
      ),
      if (hasML)
        _buildSidebarTile(
          tab: SettingsTab.mlModel,
          label: 'ML Configuration',
          icon: Icons.psychology_rounded,
          palette: palette,
        ),
      const SizedBox(height: 12),
      Divider(
          color: palette?.border ?? Theme.of(context).dividerColor, height: 1),
      const SizedBox(height: 12),
      _buildSidebarTile(
        tab: SettingsTab.about,
        label: 'About Qpic',
        icon: Icons.info_outline_rounded,
        palette: palette,
      ),
      _buildSidebarTile(
        tab: SettingsTab.privacy,
        label: 'Privacy Policy',
        icon: Icons.shield_outlined,
        palette: palette,
      ),
    ];
  }

  Widget _buildSidebarTile({
    required SettingsTab tab,
    required String label,
    required IconData icon,
    required QpicPalette? palette,
  }) {
    final theme = Theme.of(context);
    final active = _activeTab == tab;
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final activeBg = brand.withValues(alpha: 0.1);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: active ? activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: active
            ? Border(
                left: BorderSide(color: brand, width: 3),
              )
            : null,
      ),
      child: ListTile(
        visualDensity: VisualDensity.compact,
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Icon(
          icon,
          color: active ? brand : muted,
          size: 18,
        ),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.bold : FontWeight.w500,
            color: active ? text : muted,
          ),
        ),
        selected: active,
        onTap: () {
          setState(() {
            _activeTab = tab;
          });
        },
      ),
    );
  }

  Widget _buildActiveTabContent(BuildContext context, QpicPalette? palette) {
    switch (_activeTab) {
      case SettingsTab.general:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _CategoryHeader(title: 'THEME', palette: palette),
            const SizedBox(height: 10),
            _buildThemeSelector(context, palette),
            const SizedBox(height: 24),
            _CategoryHeader(title: 'DEFAULT TOOL CONFIG', palette: palette),
            const SizedBox(height: 14),
            _buildDpiConfig(context, palette),
            const SizedBox(height: 16),
            _buildPaddingConfig(context, palette),
          ],
        );
      case SettingsTab.naming:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _CategoryHeader(title: 'OUTPUT & NAMING', palette: palette),
            const SizedBox(height: 14),
            _buildNamingConfig(context, palette),
            const SizedBox(height: 16),
            _buildImageFormatConfig(context, palette),
            const SizedBox(height: 16),
            _buildSmartModeConfig(context, palette),
          ],
        );
      case SettingsTab.mlModel:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _CategoryHeader(title: 'ML MODEL CONFIGURATION', palette: palette),
            const SizedBox(height: 14),
            _buildMlModelConfig(context, palette),
            const SizedBox(height: 24),
            _CategoryHeader(title: 'ENGINE STATUS', palette: palette),
            const SizedBox(height: 12),
            _buildEngineStatusCard(context, palette),
          ],
        );
      case SettingsTab.about:
        return _buildAboutContent(context, palette);
      case SettingsTab.privacy:
        return _buildPrivacyContent(context, palette);
    }
  }

  Widget _buildAboutContent(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return Column(
      children: <Widget>[
        const SizedBox(height: 10),
        // Large Logo
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: brand.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
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
            color: text,
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
            color: text,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 32),
        // Copyright & Author Link
        Text(
          'Copyright © 2026 Qpic. All rights reserved.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 6),
        Text.rich(
          TextSpan(
            children: <TextSpan>[
              TextSpan(
                text: 'Developer: ',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              TextSpan(
                text: 'aniketmishra',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: brand,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyContent(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;
    final panelAlt = palette?.panelAlt ?? theme.colorScheme.surfaceContainerLow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Alert card stating local nature
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
                        color: text,
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
          theme: theme,
          brand: brand,
          text: text,
          muted: muted,
          icon: Icons.computer_rounded,
          title: '100% Local Processing',
          description:
              'All PDF parsing, question detection, and image cropping run entirely on your device. No files are sent to remote servers unless you explicitly enable Online mode.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme: theme,
          brand: brand,
          text: text,
          muted: muted,
          icon: Icons.block_rounded,
          title: 'Zero Telemetry & Analytics',
          description:
              'No tracking scripts, cookies, or usage telemetry. We do not monitor your activity, collect analytics, or report any data back to us.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme: theme,
          brand: brand,
          text: text,
          muted: muted,
          icon: Icons.psychology_rounded,
          title: 'Local ML Detection',
          description:
              'The built-in ML model (YOLOv8/ONNX) runs fully offline. It detects question and solution regions as bounding box coordinates only \u2014 it does not read, extract, or understand your document content.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme: theme,
          brand: brand,
          text: text,
          muted: muted,
          icon: Icons.cloud_off_rounded,
          title: 'Online AI (Optional)',
          description:
              'When Online mode is enabled, only page images are sent to your configured AI provider (Anthropic or OpenRouter) to obtain question region coordinates. No document content is extracted, stored, or retained by the app or the AI provider.',
        ),
        const SizedBox(height: 14),
        _buildPrivacyPoint(
          theme: theme,
          brand: brand,
          text: text,
          muted: muted,
          icon: Icons.storage_rounded,
          title: 'Secure Local File Handling',
          description:
              'Your documents and exported cropped images remain strictly within your local file system. Temporary job files are automatically cleaned up after processing.',
        ),
      ],
    );
  }

  Widget _buildPrivacyPoint({
    required ThemeData theme,
    required Color brand,
    required Color text,
    required Color muted,
    required IconData icon,
    required String title,
    required String description,
  }) {
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
                  color: text,
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
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.3,
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
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? brand.withValues(alpha: 0.3) : Colors.transparent,
            width: 1.0,
          ),
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
