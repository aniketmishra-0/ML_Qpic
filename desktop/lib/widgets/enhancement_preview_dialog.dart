import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/theme_controller.dart';

class EnhancementPreviewDialog extends StatefulWidget {
  const EnhancementPreviewDialog({
    super.key,
    required this.apiClient,
    required this.jobId,
    required this.totalPages,
    required this.initialContrast,
    required this.initialBrightness,
    required this.initialWatermarkThreshold,
    required this.initialBinarize,
    required this.initialDeskew,
    required this.onApply,
  });

  final ApiClient apiClient;
  final String jobId;
  final int totalPages;
  final double initialContrast;
  final double initialBrightness;
  final int initialWatermarkThreshold;
  final bool initialBinarize;
  final bool initialDeskew;
  final Function(double contrast, double brightness, int watermarkThreshold,
      bool binarize, bool deskew) onApply;

  @override
  State<EnhancementPreviewDialog> createState() =>
      _EnhancementPreviewDialogState();
}

class _EnhancementPreviewDialogState extends State<EnhancementPreviewDialog> {
  int _currentPage = 1;
  late double _contrast;
  late double _brightness;
  late int _watermarkThreshold;
  late bool _binarize;
  late bool _deskew;

  @override
  void initState() {
    super.initState();
    _contrast = widget.initialContrast;
    _brightness = widget.initialBrightness;
    _watermarkThreshold = widget.initialWatermarkThreshold;
    _binarize = widget.initialBinarize;
    _deskew = widget.initialDeskew;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    // Resolve URLs
    final originalUrl = widget.apiClient
        .resolveUri('/api/tools/edit/${widget.jobId}/page/$_currentPage');

    // Construct dynamic enhance URL with parameters
    final enhancePath = '/api/tools/enhance/${widget.jobId}/page/$_currentPage'
        '?contrast=$_contrast'
        '&brightness=$_brightness'
        '&watermark_threshold=$_watermarkThreshold'
        '&binarize=$_binarize'
        '&deskew=$_deskew';
    final enhancedUrl = widget.apiClient.resolveUri(enhancePath);

    return Dialog(
      backgroundColor: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border, width: 1.0),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 750),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: brand.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.preview_outlined, color: brand, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Enhancement Calibration Preview',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: text,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tune parameters and compare results side-by-side in real-time',
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

            // Content side-by-side views + controls
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left side comparison
                  Expanded(
                    flex: 7,
                    child: Container(
                      color: palette?.panelAlt ??
                          theme.colorScheme.surfaceContainerLow,
                      child: Column(
                        children: [
                          // Page navigator bar
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 8.0, horizontal: 16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                OutlinedButton.icon(
                                  icon: const Icon(
                                      Icons.arrow_back_ios_new_rounded,
                                      size: 14),
                                  label: const Text('Prev'),
                                  onPressed: _currentPage > 1
                                      ? () => setState(() => _currentPage--)
                                      : null,
                                ),
                                Text(
                                  'Page $_currentPage of ${widget.totalPages}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: text,
                                  ),
                                ),
                                OutlinedButton.icon(
                                  label: const Text('Next'),
                                  icon: const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      size: 14),
                                  onPressed: _currentPage < widget.totalPages
                                      ? () => setState(() => _currentPage++)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                          Divider(color: border, height: 1),
                          Expanded(
                            child: Row(
                              children: [
                                // Original View
                                Expanded(
                                  child: Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        color: palette?.field
                                                ?.withValues(alpha: 0.5) ??
                                            theme.colorScheme
                                                .surfaceContainerHighest,
                                        width: double.infinity,
                                        child: Center(
                                          child: Text(
                                            'ORIGINAL',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 0.5,
                                              color: text,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Image.network(
                                            originalUrl.toString(),
                                            fit: BoxFit.contain,
                                            loadingBuilder:
                                                (context, child, progress) {
                                              if (progress == null)
                                                return child;
                                              return const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2.5));
                                            },
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                VerticalDivider(color: border, width: 1),

                                // Enhanced Preview View
                                Expanded(
                                  child: Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        color: brand.withValues(alpha: 0.1),
                                        width: double.infinity,
                                        child: Center(
                                          child: Text(
                                            'ENHANCED PREVIEW',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 0.5,
                                              color: brand,
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
                                                '$_currentPage-$_binarize-$_deskew-$_contrast-$_brightness-$_watermarkThreshold'),
                                            fit: BoxFit.contain,
                                            loadingBuilder:
                                                (context, child, progress) {
                                              if (progress == null)
                                                return child;
                                              return const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2.5));
                                            },
                                            errorBuilder:
                                                (context, error, stackTrace) {
                                              return const Center(
                                                child: Text(
                                                  'Failed to render enhanced preview.',
                                                  style:
                                                      TextStyle(fontSize: 12),
                                                ),
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
                      ),
                    ),
                  ),

                  VerticalDivider(color: border, width: 1),

                  // Right side sliders / parameters tuning
                  Expanded(
                    flex: 3,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CALIBRATION CONTROLS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: palette?.mutedAlt ??
                                  theme.colorScheme.onSurfaceVariant,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Contrast
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Contrast Scale',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: text),
                              ),
                              Text(
                                _contrast.toStringAsFixed(2),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: text),
                              ),
                            ],
                          ),
                          Slider(
                            value: _contrast,
                            min: 0.5,
                            max: 3.0,
                            divisions: 25,
                            onChanged: (val) => setState(() => _contrast = val),
                          ),
                          const SizedBox(height: 12),

                          // Brightness
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Brightness Scale',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: text),
                              ),
                              Text(
                                _brightness.toStringAsFixed(2),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: text),
                              ),
                            ],
                          ),
                          Slider(
                            value: _brightness,
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            onChanged: (val) =>
                                setState(() => _brightness = val),
                          ),
                          const SizedBox(height: 12),

                          // Watermark
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Watermark Filter',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: text),
                              ),
                              Text(
                                _watermarkThreshold == 255
                                    ? 'Off'
                                    : '$_watermarkThreshold',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: text),
                              ),
                            ],
                          ),
                          Slider(
                            value: _watermarkThreshold.toDouble(),
                            min: 0,
                            max: 255,
                            divisions: 255,
                            onChanged: (val) => setState(
                                () => _watermarkThreshold = val.round()),
                          ),
                          const SizedBox(height: 12),

                          // Binarize
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Binarize (Pure B&W)',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: text),
                            ),
                            value: _binarize,
                            onChanged: (val) => setState(() => _binarize = val),
                          ),

                          // Deskew
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Deskew Pages',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: text),
                            ),
                            value: _deskew,
                            onChanged: (val) => setState(() => _deskew = val),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: border, height: 1),

            // Footer Actions
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () {
                      widget.onApply(_contrast, _brightness,
                          _watermarkThreshold, _binarize, _deskew);
                      Navigator.of(context).pop();
                    },
                    child: const Text('Apply Enhancement Settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
