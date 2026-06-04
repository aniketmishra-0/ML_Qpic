import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/file_picker_service.dart';
import '../../core/theme_controller.dart';
import '../../widgets/drop_target.dart';

/// Standalone Image Enhancement Pipeline Tool View.
///
/// Two modes:
///   • **Manual** — traditional sliders (denoise, contrast, brightness, etc.)
///   • **AI Enhance** — one-click Remini-like enhancement using OpenCV NLM +
///     CLAHE + Detail Enhancement + Unsharp Mask, with optional HF online SR.
class ImageEnhancementView extends StatefulWidget {
  const ImageEnhancementView({
    super.key,
    required this.apiClient,
    required this.downloadService,
  });

  final ApiClient apiClient;
  final DownloadService downloadService;

  @override
  State<ImageEnhancementView> createState() => _ImageEnhancementViewState();
}

class _ImageEnhancementViewState extends State<ImageEnhancementView>
    with SingleTickerProviderStateMixin {
  // File state
  Uint8List? _fileBytes;
  String? _fileName;
  Uint8List? _enhancedBytes;

  // Tab: 0 = AI Enhance, 1 = Manual
  late TabController _tabController;
  int _activeTab = 0;

  // --- AI Enhance parameters ---
  int _aiStrength = 3;       // 1–5
  bool _faceEnhance = true;
  int _aiSharpen = 3;        // 0–5
  int _aiUpscale = 1;        // 1 or 2
  bool _colorFix = true;
  bool _onlineSr = false;    // HF super-resolution

  // --- Manual parameters ---
  int _denoise = 0;
  double _contrast = 1.0;
  double _brightness = 1.0;
  int _watermarkThreshold = 255;
  bool _binarize = false;
  int _binarizeThreshold = 185;
  bool _deskew = false;

  // Loading & Error states
  bool _busy = false;
  String? _errorText;

  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != _activeTab) {
        setState(() {
          _activeTab = _tabController.index;
          _enhancedBytes = null;
          _errorText = null;
        });
        if (_fileBytes != null) {
          _applyEnhancement();
        }
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await fs.openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: 'Images',
            extensions: FilePickerService.imageExtensions,
            uniformTypeIdentifiers: <String>['public.image'],
            mimeTypes: <String>['image/*'],
          ),
        ],
      );
      if (result == null) return;
      final bytes = await result.readAsBytes();
      _setFile(bytes, result.name);
    } catch (e) {
      setState(() => _errorText = 'Could not load image file: $e');
    }
  }

  void _setFile(Uint8List bytes, String name) {
    setState(() {
      _fileBytes = bytes;
      _fileName = name;
      _enhancedBytes = null;
      _errorText = null;
      _busy = true;
    });

    _applyEnhancement();
  }

  void _onParameterChanged() {
    if (_fileBytes == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _applyEnhancement();
    });
  }

  Future<void> _applyEnhancement() async {
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    setState(() {
      _busy = true;
      _errorText = null;
    });

    try {
      late final List<int> enhanced;

      if (_activeTab == 0) {
        // AI Enhance mode
        enhanced = await widget.apiClient.aiEnhanceImage(
          fileBytes: bytes,
          filename: name,
          strength: _aiStrength,
          faceEnhance: _faceEnhance,
          sharpen: _aiSharpen,
          upscale: _aiUpscale,
          colorFix: _colorFix,
          onlineSr: _onlineSr,
        );
      } else {
        // Manual mode
        enhanced = await widget.apiClient.enhanceImage(
          fileBytes: bytes,
          filename: name,
          binarize: _binarize,
          binarizeThreshold: _binarizeThreshold,
          contrast: _contrast,
          brightness: _brightness,
          watermarkThreshold: _watermarkThreshold,
          denoise: _denoise,
          deskew: _deskew,
        );
      }

      setState(() {
        _enhancedBytes = Uint8List.fromList(enhanced);
        _busy = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _errorText = 'Enhancement failed: ${e.detail}';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _errorText = 'Failed to enhance image: $e';
        _busy = false;
      });
    }
  }

  void _clear() {
    _debounceTimer?.cancel();
    setState(() {
      _fileBytes = null;
      _fileName = null;
      _enhancedBytes = null;
      _errorText = null;
      _busy = false;
      // Reset AI params
      _aiStrength = 3;
      _faceEnhance = true;
      _aiSharpen = 3;
      _aiUpscale = 1;
      _colorFix = true;
      _onlineSr = false;
      // Reset manual params
      _denoise = 0;
      _contrast = 1.0;
      _brightness = 1.0;
      _watermarkThreshold = 255;
      _binarize = false;
      _binarizeThreshold = 185;
      _deskew = false;
    });
  }

  Future<void> _downloadImage() async {
    final bytes = _enhancedBytes ?? _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    setState(() {
      _busy = true;
      _errorText = null;
    });

    try {
      final dotIdx = name.lastIndexOf('.');
      final stem = dotIdx == -1 ? name : name.substring(0, dotIdx);
      final ext = dotIdx == -1 ? 'png' : name.substring(dotIdx + 1);
      final suggestedName = 'enhanced_$stem.$ext';

      final saveLocation = await fs.getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Images',
            extensions: [ext, 'png', 'jpg', 'jpeg'],
          ),
        ],
      );

      if (saveLocation != null && saveLocation.path.isNotEmpty) {
        final file = File(saveLocation.path);
        await file.writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image saved successfully to: ${saveLocation.path}'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _errorText = 'Failed to save image: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    final Widget subView = _fileBytes == null
        ? _buildUploadDropZone(context, palette)
        : _buildEnhancerInterface(context, palette);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Image Enhancement Pipeline',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'AI-powered image restoration & manual enhancement tools.',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: palette?.muted ??
                            theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (_fileBytes != null)
                TextButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Main Layout
          Expanded(
            child: subView,
          ),
        ],
      ),
    );
  }

  // --- Upload drop zone ---
  Widget _buildUploadDropZone(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return DropFileTarget(
      acceptedExtensions: FilePickerService.imageExtensions,
      onAccepted: (files) async {
        if (files.isEmpty) return;
        final file = files.first;
        try {
          final bytes = await file.readAsBytes();
          _setFile(bytes, file.name);
        } catch (e) {
          setState(() => _errorText = 'Could not read image file: $e');
        }
      },
      onRejected: (message) {
        setState(() => _errorText =
            'Invalid file type. Only image documents are supported.');
      },
      overlayBuilder: (context, isDragOver, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: isDragOver
                ? brand.withValues(alpha: 0.04)
                : (palette?.panel ?? theme.colorScheme.surface),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isDragOver ? brand : (palette?.border ?? theme.dividerColor),
              width: 2,
            ),
          ),
          child: child,
        );
      },
      child: GestureDetector(
        onTap: _pickFile,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: brand.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_fix_high_rounded,
                  color: brand,
                  size: 28,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Drop your image here for AI enhancement',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Supports JPEG, PNG — removes blur, noise & restores details like Remini',
                style: TextStyle(
                  fontSize: 13,
                  color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: (palette?.danger ?? theme.colorScheme.error)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: (palette?.danger ?? theme.colorScheme.error)
                            .withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _errorText!,
                    style: TextStyle(
                      color: palette?.danger ?? theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --- Main editor layout ---
  Widget _buildEnhancerInterface(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Controls Panel
            SizedBox(
              width: 340,
              child: Card(
                elevation: 0,
                color: palette?.panel ?? theme.colorScheme.surface,
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: palette?.border ?? theme.dividerColor,
                    width: 1.0,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Tab Bar
                    Container(
                      decoration: BoxDecoration(
                        color: (palette?.panel ?? theme.colorScheme.surface),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                        border: Border(
                          bottom: BorderSide(
                            color: palette?.border ?? theme.dividerColor,
                            width: 1,
                          ),
                        ),
                      ),
                      child: TabBar(
                        controller: _tabController,
                        indicatorColor: brand,
                        labelColor: brand,
                        unselectedLabelColor: palette?.muted ??
                            theme.colorScheme.onSurfaceVariant,
                        indicatorSize: TabBarIndicatorSize.tab,
                        labelStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                        tabs: const [
                          Tab(
                            icon: Icon(Icons.auto_fix_high_rounded, size: 16),
                            text: 'AI ENHANCE',
                            height: 52,
                          ),
                          Tab(
                            icon: Icon(Icons.tune_rounded, size: 16),
                            text: 'MANUAL',
                            height: 52,
                          ),
                        ],
                      ),
                    ),
                    // Tab Content
                    Expanded(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: _activeTab == 0
                              ? _buildAiControls(palette)
                              : _buildManualControls(palette),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 20),

            // Right Preview Panels
            Expanded(
              child: Card(
                elevation: 0,
                color: palette?.panel ?? theme.colorScheme.surface,
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: palette?.border ?? theme.dividerColor,
                    width: 1.0,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // Original Image Preview
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              'ORIGINAL IMAGE',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: palette?.muted ??
                                    theme.colorScheme.onSurfaceVariant,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Center(
                                  child: Image.memory(
                                    _fileBytes!,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 32, thickness: 1),
                      // Enhanced Image Preview
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              _activeTab == 0
                                  ? 'AI ENHANCED'
                                  : 'ENHANCED PREVIEW',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: palette?.muted ??
                                    theme.colorScheme.onSurfaceVariant,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  children: [
                                    Center(
                                      child: _enhancedBytes != null
                                          ? Image.memory(
                                              _enhancedBytes!,
                                              fit: BoxFit.contain,
                                            )
                                          : (_busy
                                              ? Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const CircularProgressIndicator(),
                                                    const SizedBox(height: 12),
                                                    Text(
                                                      _activeTab == 0
                                                          ? 'AI processing...'
                                                          : 'Processing...',
                                                      style: TextStyle(
                                                        color: palette?.muted ??
                                                            theme
                                                                .colorScheme
                                                                .onSurfaceVariant,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : Text(
                                                  'Waiting for result...',
                                                  style: TextStyle(
                                                    color: palette?.muted ??
                                                        theme.colorScheme
                                                            .onSurfaceVariant,
                                                  ),
                                                )),
                                    ),
                                    if (_busy && _enhancedBytes != null)
                                      Positioned(
                                        top: 8,
                                        right: 8,
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Colors.black
                                                .withValues(alpha: 0.6),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation(
                                                      Colors.white),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );

        return body;
      },
    );
  }

  // ─── AI Enhance Controls ──────────────────────────────────────────────────

  Widget _buildAiControls(QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // AI badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                brand.withValues(alpha: 0.08),
                Colors.purple.withValues(alpha: 0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: brand.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: brand),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Remini-like AI restoration — deblurs, denoises & sharpens photos automatically',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette?.text ?? theme.colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Strength slider
        _buildSlider(
          palette: palette,
          label: 'Enhancement Strength',
          value: _aiStrength.toDouble(),
          min: 1,
          max: 5,
          divisions: 4,
          displayValue: _strengthLabel(_aiStrength),
          onChanged: (val) {
            setState(() => _aiStrength = val.round());
            _onParameterChanged();
          },
        ),
        const SizedBox(height: 20),

        // Sharpen slider
        _buildSlider(
          palette: palette,
          label: 'Sharpening Passes',
          value: _aiSharpen.toDouble(),
          min: 0,
          max: 5,
          divisions: 5,
          displayValue: _aiSharpen == 0 ? 'Off' : '$_aiSharpen passes',
          onChanged: (val) {
            setState(() => _aiSharpen = val.round());
            _onParameterChanged();
          },
        ),
        const SizedBox(height: 20),

        // Face/Detail Enhance toggle
        _buildToggle(
          palette: palette,
          label: 'Detail Preserve (Faces/Text)',
          value: _faceEnhance,
          onChanged: (val) {
            setState(() => _faceEnhance = val);
            _onParameterChanged();
          },
        ),
        const SizedBox(height: 16),

        // Color Fix toggle
        _buildToggle(
          palette: palette,
          label: 'Auto Color Correction',
          value: _colorFix,
          onChanged: (val) {
            setState(() => _colorFix = val);
            _onParameterChanged();
          },
        ),
        const SizedBox(height: 16),

        // 2× Upscale toggle
        _buildToggle(
          palette: palette,
          label: '2× Upscale (Local Lanczos)',
          value: _aiUpscale == 2,
          onChanged: (val) {
            setState(() => _aiUpscale = val ? 2 : 1);
            _onParameterChanged();
          },
        ),
        const SizedBox(height: 16),

        // Online SR toggle
        _buildToggle(
          palette: palette,
          label: 'Online AI Super-Resolution (HF)',
          subtitle: 'Requires Hugging Face token in .env',
          value: _onlineSr,
          onChanged: (val) {
            setState(() => _onlineSr = val);
            _onParameterChanged();
          },
        ),
        const SizedBox(height: 24),

        // Download Button
        _buildDownloadButton(palette),

        if (_errorText != null) ...[
          const SizedBox(height: 12),
          _buildErrorText(palette),
        ],
      ],
    );
  }

  String _strengthLabel(int s) {
    switch (s) {
      case 1:
        return 'Subtle';
      case 2:
        return 'Light';
      case 3:
        return 'Medium';
      case 4:
        return 'Strong';
      case 5:
        return 'Aggressive';
      default:
        return 'Medium';
    }
  }

  // ─── Manual Controls ──────────────────────────────────────────────────────

  Widget _buildManualControls(QpicPalette? palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildDenoiseSlider(palette),
        const SizedBox(height: 20),
        _buildContrastSlider(palette),
        const SizedBox(height: 20),
        _buildBrightnessSlider(palette),
        const SizedBox(height: 20),
        _buildWatermarkSlider(palette),
        const SizedBox(height: 20),
        _buildBinarizeToggle(palette),
        const SizedBox(height: 20),
        _buildDeskewToggle(palette),
        const SizedBox(height: 24),

        // Download Button
        _buildDownloadButton(palette),

        if (_errorText != null) ...[
          const SizedBox(height: 12),
          _buildErrorText(palette),
        ],
      ],
    );
  }

  // ─── Shared widget builders ───────────────────────────────────────────────

  Widget _buildSlider({
    required QpicPalette? palette,
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: palette?.text ?? theme.colorScheme.onSurface,
              ),
            ),
            Text(
              displayValue,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: brand,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: brand,
            thumbColor: brand,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildToggle({
    required QpicPalette? palette,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: palette?.muted ??
                          theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: brand,
          activeTrackColor: brand.withValues(alpha: 0.5),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildDownloadButton(QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return ElevatedButton.icon(
      onPressed: _busy ? null : _downloadImage,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          : const Icon(Icons.download_rounded, size: 18),
      label: const Text('Download Enhanced Image'),
      style: ElevatedButton.styleFrom(
        backgroundColor: brand,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Widget _buildErrorText(QpicPalette? palette) {
    final theme = Theme.of(context);
    return Text(
      _errorText!,
      style: TextStyle(
        color: palette?.danger ?? theme.colorScheme.error,
        fontSize: 12.5,
      ),
      textAlign: TextAlign.center,
    );
  }

  // ─── Manual slider builders (unchanged) ───────────────────────────────────

  Widget _buildDenoiseSlider(QpicPalette? palette) {
    return _buildSlider(
      palette: palette,
      label: 'Noise Reduction (Denoise)',
      value: _denoise.toDouble(),
      min: 0,
      max: 5,
      divisions: 5,
      displayValue: _denoise == 0 ? 'Off' : 'Level $_denoise',
      onChanged: (val) {
        setState(() => _denoise = val.round());
        _onParameterChanged();
      },
    );
  }

  Widget _buildContrastSlider(QpicPalette? palette) {
    return _buildSlider(
      palette: palette,
      label: 'Contrast',
      value: _contrast,
      min: 0.1,
      max: 3.0,
      displayValue: '${_contrast.toStringAsFixed(1)}x',
      onChanged: (val) {
        setState(() => _contrast = val);
        _onParameterChanged();
      },
    );
  }

  Widget _buildBrightnessSlider(QpicPalette? palette) {
    return _buildSlider(
      palette: palette,
      label: 'Brightness',
      value: _brightness,
      min: 0.1,
      max: 3.0,
      displayValue: '${_brightness.toStringAsFixed(1)}x',
      onChanged: (val) {
        setState(() => _brightness = val);
        _onParameterChanged();
      },
    );
  }

  Widget _buildWatermarkSlider(QpicPalette? palette) {
    return _buildSlider(
      palette: palette,
      label: 'Watermark Remover (RGB)',
      value: _watermarkThreshold.toDouble(),
      min: 0,
      max: 255,
      displayValue:
          _watermarkThreshold == 255 ? 'Off' : 'Threshold $_watermarkThreshold',
      onChanged: (val) {
        setState(() => _watermarkThreshold = val.round());
        _onParameterChanged();
      },
    );
  }

  Widget _buildBinarizeToggle(QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToggle(
          palette: palette,
          label: 'Convert to High-Contrast B&W',
          value: _binarize,
          onChanged: (val) {
            setState(() => _binarize = val);
            _onParameterChanged();
          },
        ),
        if (_binarize) ...[
          const SizedBox(height: 12),
          _buildSlider(
            palette: palette,
            label: 'Binarization Threshold',
            value: _binarizeThreshold.toDouble(),
            min: 0,
            max: 255,
            displayValue: '$_binarizeThreshold',
            onChanged: (val) {
              setState(() => _binarizeThreshold = val.round());
              _onParameterChanged();
            },
          ),
        ],
      ],
    );
  }

  Widget _buildDeskewToggle(QpicPalette? palette) {
    return _buildToggle(
      palette: palette,
      label: 'Straighten Tilt (Deskew)',
      value: _deskew,
      onChanged: (val) {
        setState(() => _deskew = val);
        _onParameterChanged();
      },
    );
  }
}
