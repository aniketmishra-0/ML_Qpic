import 'dart:typed_data';
import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/file_picker_service.dart';
import '../../core/theme_controller.dart';
import '../auto_crop/auto_crop_controller.dart';
import '../manual_crop/manual_crop_controller.dart';
import '../../widgets/drop_target.dart';

/// PDF Enhancer and Quality Editor Tool View.
///
/// Provides sliders to adjust brightness, contrast, watermark threshold, and
/// binarization on an uploaded PDF. Features live before/after previews and
/// enables downloading or forwarding the enhanced PDF straight to crop workflows.
class PdfEnhancerView extends StatefulWidget {
  const PdfEnhancerView({
    super.key,
    required this.apiClient,
    required this.downloadService,
    required this.autoCropController,
    required this.manualCropController,
    required this.themeController,
    required this.onSwitchTab,
  });

  final ApiClient? apiClient;
  final DownloadService? downloadService;
  final AutoCropController autoCropController;
  final ManualCropController manualCropController;
  final ThemeController themeController;
  final ValueChanged<int> onSwitchTab; // 0 = Auto Crop, 1 = Manual Crop

  @override
  State<PdfEnhancerView> createState() => _PdfEnhancerViewState();
}

class _PdfEnhancerViewState extends State<PdfEnhancerView> {
  // File state
  Uint8List? _fileBytes;
  String? _fileName;

  // Stashed session details
  String? _jobId;
  int _totalPages = 0;
  int _currentPage = 1; // 1-indexed

  // Enhancer parameters
  double _contrast = 1.0;
  double _brightness = 1.0;
  int _watermarkThreshold = 255; // 255 = Off
  bool _binarize = false;
  int _dpi = 150;

  // Loading & Error states
  bool _busy = false;
  bool _previewLoading = false;
  String? _errorText;
  String? _successNote;
  String? _enhancedDownloadUrl;

  Future<void> _pickFile() async {
    try {
      final result = await const FilePickerService().pickPdf();
      if (result == null) return;
      final bytes = await result.readAsBytes();
      _setFile(bytes, result.name);
    } catch (e) {
      setState(() => _errorText = 'Could not load PDF file: $e');
    }
  }

  void _setFile(Uint8List bytes, String name) {
    setState(() {
      _fileBytes = bytes;
      _fileName = name;
      _jobId = null;
      _totalPages = 0;
      _currentPage = 1;
      _errorText = null;
      _successNote = null;
      _enhancedDownloadUrl = null;
      _busy = true;
    });

    _stashPdfOnBackend();
  }

  Future<void> _stashPdfOnBackend() async {
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    final client = widget.apiClient;
    if (client == null) return;

    try {
      final res = await client.editOpen(
        fileBytes: bytes,
        filename: name,
      );
      setState(() {
        _jobId = res.jobId;
        _totalPages = res.pages.length;
        _busy = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _errorText = 'Failed to load PDF on server: ${e.detail}';
        _busy = false;
        _fileBytes = null;
        _fileName = null;
      });
    } catch (e) {
      setState(() {
        _errorText = 'Failed to connect to backend: $e';
        _busy = false;
        _fileBytes = null;
        _fileName = null;
      });
    }
  }

  void _clear() {
    setState(() {
      _fileBytes = null;
      _fileName = null;
      _jobId = null;
      _totalPages = 0;
      _currentPage = 1;
      _errorText = null;
      _successNote = null;
      _enhancedDownloadUrl = null;
      _busy = false;
      _contrast = 1.0;
      _brightness = 1.0;
      _watermarkThreshold = 255;
      _binarize = false;
      _dpi = 150;
    });
  }

  Future<void> _processAndEnhancePdf() async {
    final bytes = _fileBytes;
    final name = _fileName;
    if (bytes == null || name == null) return;

    final client = widget.apiClient;
    if (client == null) return;

    setState(() {
      _busy = true;
      _errorText = null;
      _successNote = null;
      _enhancedDownloadUrl = null;
    });

    try {
      final res = await client.enhance(
        fileBytes: bytes,
        filename: name,
        binarize: _binarize,
        contrast: _contrast,
        brightness: _brightness,
        watermarkThreshold: _watermarkThreshold,
        dpi: 200, // Process full PDF at high quality
      );

      setState(() {
        _enhancedDownloadUrl = res.downloadUrl;
        _busy = false;
        _successNote = 'PDF enhanced successfully! You can download it or send it to crops.';
      });
    } on ApiException catch (e) {
      setState(() {
        _errorText = 'Enhancement failed: ${e.detail}';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _errorText = 'Failed to enhance PDF: $e';
        _busy = false;
      });
    }
  }

  Future<void> _downloadEnhancedPdf() async {
    final url = _enhancedDownloadUrl;
    final name = _fileName;
    final client = widget.apiClient;
    final downloader = widget.downloadService;
    if (url == null || name == null || client == null || downloader == null) return;

    setState(() {
      _busy = true;
      _errorText = null;
    });

    try {
      final downloadUri = client.resolveUri(url);
      final suggestedName = 'enhanced_$name';
      await downloader.download(
        engineUrl: downloadUri.toString(),
        suggestedName: suggestedName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PDF Documents', extensions: ['pdf']),
        ],
      );
      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _errorText = 'Download failed: $e';
        _busy = false;
      });
    }
  }

  Future<void> _sendToCrop(bool autoMode) async {
    final url = _enhancedDownloadUrl;
    final name = _fileName;
    final client = widget.apiClient;
    if (url == null || name == null || client == null) return;

    setState(() {
      _busy = true;
      _errorText = null;
    });

    try {
      final bytes = await client.getBytes(url);
      final suggestedName = 'enhanced_$name';

      if (autoMode) {
        widget.autoCropController.setFile(bytes: bytes, filename: suggestedName);
        widget.autoCropController.applyDefaults(widget.themeController);
        widget.onSwitchTab(0); // Switch to Auto Crop tab
      } else {
        widget.manualCropController.setFile(bytes: bytes, filename: suggestedName);
        widget.manualCropController.applyDefaults(widget.themeController);
        widget.onSwitchTab(1); // Switch to Manual Crop tab
      }

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _errorText = 'Failed to send to crops: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    if (widget.apiClient == null || widget.downloadService == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Waiting for engine connection...',
              style: TextStyle(color: palette?.muted ?? theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
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
                      'PDF Enhancer & Watermark Remover',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Remove faint watermarks, boost text contrast, and save the original PDF or crop directly.',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (_fileBytes != null && !_busy)
                TextButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Main Layout
          Expanded(
            child: _fileBytes == null
                ? _buildUploadDropZone(context, palette)
                : _buildEnhancerInterface(context, palette),
          ),
        ],
      ),
    );
  }

  // --- Upload drop zone ---
  Widget _buildUploadDropZone(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return DropFileTarget.pdfOnly(
      onAccepted: (files) async {
        if (files.isEmpty) return;
        final file = files.first;
        try {
          final bytes = await file.readAsBytes();
          _setFile(bytes, file.name);
        } catch (e) {
          setState(() => _errorText = 'Could not read PDF file: $e');
        }
      },
      onRejected: (message) {
        setState(() => _errorText = 'Invalid file type. Only PDF documents are supported.');
      },
      overlayBuilder: (context, isDragOver, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: isDragOver
                ? brand.withValues(alpha: 0.04)
                : (palette?.panel ?? theme.colorScheme.surface),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDragOver ? brand : (palette?.border ?? theme.dividerColor),
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
                  Icons.picture_as_pdf_rounded,
                  color: brand,
                  size: 28,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Drop your PDF here to enhance',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'or click to browse local files',
                style: TextStyle(
                  fontSize: 13,
                  color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: (palette?.danger ?? theme.colorScheme.error).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: (palette?.danger ?? theme.colorScheme.error).withValues(alpha: 0.3)),
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
    final isStashed = _jobId != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        final body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Controls Panel
            SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Card(
                  color: palette?.panel ?? theme.colorScheme.surface,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'ENHANCEMENT SETTINGS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Sliders & Toggles
                        _buildWatermarkSlider(palette),
                        const SizedBox(height: 20),
                        _buildContrastSlider(palette),
                        const SizedBox(height: 20),
                        _buildBrightnessSlider(palette),
                        const SizedBox(height: 20),
                        _buildBinarizeToggle(palette),
                        const SizedBox(height: 20),
                        _buildDpiSelector(palette),
                        const SizedBox(height: 24),

                        // Error Banner if any
                        if (_errorText != null) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: (palette?.danger ?? theme.colorScheme.error).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _errorText!,
                              style: TextStyle(
                                color: palette?.danger ?? theme.colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Success Banner if any
                        if (_successNote != null) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: (palette?.success ?? theme.colorScheme.primary).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _successNote!,
                              style: TextStyle(
                                color: palette?.success ?? theme.colorScheme.primary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Primary Action: Enhance PDF
                        if (_enhancedDownloadUrl == null)
                          FilledButton.icon(
                            onPressed: _busy ? null : _processAndEnhancePdf,
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.auto_awesome_rounded),
                            label: const Text('Enhance entire PDF'),
                          )
                        else ...[
                          FilledButton.icon(
                            onPressed: _busy ? null : _downloadEnhancedPdf,
                            icon: const Icon(Icons.download_rounded),
                            label: const Text('Save Enhanced PDF'),
                            style: FilledButton.styleFrom(
                              backgroundColor: palette?.success ?? theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _sendToCrop(true),
                            icon: const Icon(Icons.crop_rounded),
                            label: const Text('Send to Auto Crop'),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _sendToCrop(false),
                            icon: const Icon(Icons.crop_free_rounded),
                            label: const Text('Send to Manual Crop'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),

            // Right Previews Panel
            Expanded(
              child: Card(
                color: palette?.panel ?? theme.colorScheme.surface,
                margin: EdgeInsets.zero,
                child: isStashed
                    ? _buildPreviewCanvas(palette)
                    : const Center(
                        child: CircularProgressIndicator(),
                      ),
              ),
            ),
          ],
        );

        return body;
      },
    );
  }

  // --- Watermark Removal Threshold Slider ---
  Widget _buildWatermarkSlider(QpicPalette? palette) {
    final text = palette?.text ?? Colors.black;
    final isOff = _watermarkThreshold == 255;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Watermark Threshold',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text),
            ),
            Text(
              isOff ? 'Off' : '$_watermarkThreshold RGB',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: palette?.brand),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Removes faint grey background watermarks',
          style: TextStyle(fontSize: 10.5, color: palette?.muted),
        ),
        const SizedBox(height: 4),
        Slider(
          value: _watermarkThreshold.toDouble(),
          min: 150,
          max: 255,
          divisions: 105,
          onChanged: (val) {
            setState(() {
              _watermarkThreshold = val.round();
              _enhancedDownloadUrl = null; // Reset result so user has to re-generate
            });
          },
        ),
      ],
    );
  }

  // --- Contrast Slider ---
  Widget _buildContrastSlider(QpicPalette? palette) {
    final text = palette?.text ?? Colors.black;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Text Contrast',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text),
            ),
            Text(
              '${_contrast.toStringAsFixed(1)}x',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: palette?.brand),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Darkens text and brightens background',
          style: TextStyle(fontSize: 10.5, color: palette?.muted),
        ),
        const SizedBox(height: 4),
        Slider(
          value: _contrast,
          min: 1.0,
          max: 3.0,
          divisions: 20,
          onChanged: (val) {
            setState(() {
              _contrast = val;
              _enhancedDownloadUrl = null;
            });
          },
        ),
      ],
    );
  }

  // --- Brightness Slider ---
  Widget _buildBrightnessSlider(QpicPalette? palette) {
    final text = palette?.text ?? Colors.black;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Brightness',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text),
            ),
            Text(
              '${_brightness.toStringAsFixed(1)}x',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: palette?.brand),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Slider(
          value: _brightness,
          min: 0.5,
          max: 2.0,
          divisions: 30,
          onChanged: (val) {
            setState(() {
              _brightness = val;
              _enhancedDownloadUrl = null;
            });
          },
        ),
      ],
    );
  }

  // --- Binarization Toggle ---
  Widget _buildBinarizeToggle(QpicPalette? palette) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Binarize (Pure B&W)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      subtitle: const Text('Convert pages to sharp monochrome text', style: TextStyle(fontSize: 10.5)),
      value: _binarize,
      onChanged: (val) {
        setState(() {
          _binarize = val;
          _enhancedDownloadUrl = null;
        });
      },
    );
  }

  // --- Preview DPI Selector ---
  Widget _buildDpiSelector(QpicPalette? palette) {
    final text = palette?.text ?? Colors.black;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preview Quality', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text)),
            Text('Resolution density', style: TextStyle(fontSize: 10.5, color: palette?.muted)),
          ],
        ),
        DropdownButton<int>(
          value: _dpi,
          items: const [
            DropdownMenuItem(value: 72, child: Text('72 DPI')),
            DropdownMenuItem(value: 150, child: Text('150 DPI')),
            DropdownMenuItem(value: 200, child: Text('200 DPI')),
          ],
          onChanged: (val) {
            if (val != null) {
              setState(() => _dpi = val);
            }
          },
        ),
      ],
    );
  }

  // --- Preview Canvas Grid/Layout ---
  Widget _buildPreviewCanvas(QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? Colors.black;
    final muted = palette?.muted ?? Colors.grey;

    final client = widget.apiClient;
    if (client == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final originalUrl = client.resolveUri(
      '/api/tools/edit/$_jobId/page/$_currentPage'
    );
    final enhancedUrl = client.enhancePagePreviewUri(
      _jobId!,
      _currentPage,
      binarize: _binarize,
      contrast: _contrast,
      brightness: _brightness,
      watermarkThreshold: _watermarkThreshold,
      dpi: _dpi,
    );

    return Column(
      children: [
        // Preview Header / Page Switcher
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LIVE PREVIEW (Page $_currentPage of $_totalPages)',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: muted),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_rounded, size: 16),
                    onPressed: _currentPage > 1
                        ? () => setState(() => _currentPage--)
                        : null,
                  ),
                  Text('$_currentPage', style: TextStyle(fontWeight: FontWeight.bold, color: text)),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                    onPressed: _currentPage < _totalPages
                        ? () => setState(() => _currentPage++)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Split comparison window
        Expanded(
          child: Row(
            children: [
              // Original View
              Expanded(
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      width: double.infinity,
                      child: const Center(
                        child: Text(
                          'ORIGINAL',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Image.network(
                          originalUrl.toString(),
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),

              // Enhanced View
              Expanded(
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      color: palette?.field?.withValues(alpha: 0.5) ?? Colors.purple.withValues(alpha: 0.1),
                      width: double.infinity,
                      child: Center(
                        child: Text(
                          'ENHANCED PREVIEW',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                            color: palette?.brand,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Image.network(
                          enhancedUrl.toString(),
                          key: ValueKey(
                            '$_currentPage-$_binarize-$_contrast-$_brightness-$_watermarkThreshold-$_dpi'
                          ),
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
                          },
                          errorBuilder: (context, error, stackTrace) {
                            return const Center(
                              child: Text('Failed to render enhanced preview.', style: TextStyle(fontSize: 12)),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
