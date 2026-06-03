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
    this.subTab,
    this.onSubTabChanged,
  });

  final ApiClient? apiClient;
  final DownloadService? downloadService;
  final int? subTab;
  final ValueChanged<int>? onSubTabChanged;

  @override
  State<PdfToolsView> createState() => _PdfToolsViewState();
}

class _PdfToolsViewState extends State<PdfToolsView> {
  // Sub-tabs: 0 = Compress, 1 = Vector Editor, 2 = Preflight, 3 = Edit
  int _currentSubTab = 0;

  @override
  void initState() {
    super.initState();
    if (widget.subTab != null) {
      _currentSubTab = widget.subTab!;
    }
  }

  @override
  void didUpdateWidget(PdfToolsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.subTab != null && widget.subTab != oldWidget.subTab) {
      setState(() {
        _currentSubTab = widget.subTab!;
        _errorText = null;
      });
    }
  }

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

  // _buildSubTabs removed because navigation is now handled by the left rail

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

    String headerTitle = '';
    String headerDesc = '';
    switch (_currentSubTab) {
      case 0:
        headerTitle = 'Compress PDF';
        headerDesc = 'Reduce the file size of your PDF documents while maintaining quality.';
        break;
      case 1:
        headerTitle = 'Vector Editor';
        headerDesc = 'Directly select and delete vector graphics, images, and other objects from your PDF.';
        break;
      case 2:
        headerTitle = 'Preflight PDF';
        headerDesc = 'Check your PDF against quality profiles and fix common issues like page sizes.';
        break;
      case 3:
      default:
        headerTitle = 'Edit PDF';
        headerDesc = 'Directly edit text layers, erase objects, add links, insert images, and run OCR on scanned documents in place.';
        break;
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
                      headerTitle,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      headerDesc,
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
