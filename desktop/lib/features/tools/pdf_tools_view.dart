import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/file_picker_service.dart';
import '../../core/theme_controller.dart';
import 'compress/compress_controller.dart';
import 'compress/compress_view.dart';
import 'preflight/preflight_controller.dart';
import 'preflight/preflight_view.dart';
import 'edit/edit_controller.dart';
import 'edit/edit_view.dart';

/// PDF Tools View.
///
/// Houses utilities like PDF Compression, PDF Preflight validation, and
/// in-place editing (which is marked as coming soon).
class PdfToolsView extends StatefulWidget {
  const PdfToolsView({
    super.key,
    required this.apiClient,
    required this.downloadService,
    this.hideHeader = false,
  });

  final ApiClient? apiClient;
  final DownloadService? downloadService;
  final bool hideHeader;

  @override
  State<PdfToolsView> createState() => _PdfToolsViewState();
}

class _PdfToolsViewState extends State<PdfToolsView> {
  // Sub-tabs: 0 = Compress, 1 = Preflight, 2 = Edit
  int _currentSubTab = 0;

  CompressController? _compressController;
  PreflightController? _preflightController;
  EditController? _editController;
  String? _errorText;

  void _initControllersIfNeeded() {
    final client = widget.apiClient;
    final download = widget.downloadService;
    if (client != null && download != null) {
      _compressController ??= CompressController(apiClient: client, downloadService: download);
      _preflightController ??= PreflightController(apiClient: client, downloadService: download);
      _editController ??= EditController(api: client, downloadService: download);
    }
  }

  @override
  void dispose() {
    _compressController?.dispose();
    _preflightController?.dispose();
    _editController?.dispose();
    super.dispose();
  }

  Widget _buildSubTabs(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    final tabs = [
      (label: 'Compress PDF', icon: Icons.compress_rounded, index: 0),
      (label: 'Vector Editor', icon: Icons.shape_line_rounded, index: 1),
      (label: 'Preflight PDF', icon: Icons.fact_check_rounded, index: 2),
      (label: 'Edit PDF', icon: Icons.edit_note_rounded, index: 3),
    ];

    return Container(
      height: 48,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: tabs.map((t) {
          final active = _currentSubTab == t.index;
          final isSoon = t.index == 3; // Edit PDF is Coming Soon

          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _currentSubTab = t.index;
                _errorText = null;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: active ? brand.withValues(alpha: 0.12) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: active ? brand.withValues(alpha: 0.5) : Colors.transparent,
                  ),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      t.icon,
                      size: 16,
                      color: active ? brand : muted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        color: active ? brand : text,
                      ),
                    ),
                    if (isSoon) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: active 
                              ? brand.withValues(alpha: 0.2) 
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Soon',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: active ? brand : muted,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildComingSoon(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    const title = 'Edit PDF';
    const desc = 'Directly edit text layers, erase objects, add links, insert images, and run OCR on scanned documents in place.';
    const icon = Icons.edit_note_rounded;

    return Center(
      child: Card(
        color: palette?.panel ?? theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
        elevation: 0,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: brand.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: brand,
                  size: 32,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: text,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: brand.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: brand.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      'COMING SOON',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: brand,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                desc,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  color: muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, color: brand, size: 18),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'This feature is currently under active development. Stay tuned for upcoming updates!',
                        style: TextStyle(
                          fontSize: 12,
                          color: text.withValues(alpha: 0.8),
                          height: 1.4,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    _initControllersIfNeeded();
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

    Widget subView;
    switch (_currentSubTab) {
      case 0:
        subView = CompressView(
          controller: _compressController!,
          onPickFile: () async {
            try {
              final result = await const FilePickerService().pickPdf();
              if (result == null) return;
              final bytes = await result.readAsBytes();
              _compressController!.setFile(bytes: bytes, filename: result.name);
            } catch (e) {
              setState(() => _errorText = 'Could not load PDF: $e');
            }
          },
        );
        break;
      case 1:
        subView = EditView(
          controller: _editController!,
          onPickFile: () async {
            try {
              final result = await const FilePickerService().pickPdf();
              if (result == null) return;
              final bytes = await result.readAsBytes();
              _editController!.open(fileBytes: bytes, filename: result.name);
            } catch (e) {
              setState(() => _errorText = 'Could not load PDF: $e');
            }
          },
        );
        break;
      case 2:
        subView = PreflightView(
          controller: _preflightController!,
          onPickFile: () async {
            try {
              final result = await const FilePickerService().pickPdf();
              if (result == null) return;
              final bytes = await result.readAsBytes();
              _preflightController!.setFile(bytes: bytes, filename: result.name);
            } catch (e) {
              setState(() => _errorText = 'Could not load PDF: $e');
            }
          },
        );
        break;
      case 3:
      default:
        subView = _buildComingSoon(context, palette);
        break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.hideHeader) ...[
            // Header Bar
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PDF Tools',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: palette?.text ?? theme.colorScheme.onSurface,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Compress PDFs to lower file size, preflight them for quality, or edit them.',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Sub-tabs navigation
          _buildSubTabs(context, palette),

          if (_errorText != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 16),
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
          ],

          // Main Layout
          Expanded(
            child: subView,
          ),
        ],
      ),
    );
  }
}
