import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../core/file_picker_service.dart';
import '../../core/theme_controller.dart';
import 'compress/compress_controller.dart';
import 'compress/compress_view.dart';
import 'edit/edit_controller.dart';
import 'edit/edit_view.dart';
import 'preflight/preflight_controller.dart';
import 'preflight/preflight_view.dart';

/// PDF Tools View.
///
/// Houses a dashboard offering PDF Compression, PDF Preflight validation, and
/// in-place editing. Clicking a tool card opens its full view, with a back
/// button returning to the dashboard.
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
  // Sub-tabs: null = Dashboard, 0 = Compress, 1 = Vector Editor, 2 = Preflight, 3 = Edit
  int? _currentSubTab;

  @override
  void initState() {
    super.initState();
    _currentSubTab = widget.subTab;
  }

  @override
  void didUpdateWidget(PdfToolsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.subTab != oldWidget.subTab) {
      setState(() {
        _currentSubTab = widget.subTab;
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
      _compressController ??=
          CompressController(apiClient: client, downloadService: download);
      _preflightController ??=
          PreflightController(apiClient: client, downloadService: download);
      _editController ??=
          EditController(api: client, downloadService: download);
    }
  }

  @override
  void dispose() {
    _compressController?.dispose();
    _preflightController?.dispose();
    _editController?.dispose();
    super.dispose();
  }

  Widget _buildComingSoon(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    const title = 'Edit PDF';
    const desc =
        'Directly edit text layers, erase objects, add links, insert images, and run OCR on scanned documents in place.';
    const icon = Icons.edit_note_rounded;

    return Center(
      child: Card(
        color: palette?.panel ?? theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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

  Widget _buildDashboard(BuildContext context, QpicPalette? palette) {
    final theme = Theme.of(context);
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Dashboard Header
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PDF Tools',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: text,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Compress PDFs to lower file size, preflight them for quality, or edit them.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Grid/List of tools
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final useGrid = constraints.maxWidth > 500;
                    final crossAxisCount = useGrid ? 2 : 1;
                    final childAspectRatio = useGrid ? 2.3 : 2.8;

                    return GridView.count(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: childAspectRatio,
                      children: [
                        _buildToolCard(
                          context,
                          index: 0,
                          title: 'Compress PDF',
                          description:
                              'Reduce the file size of your PDF documents while maintaining quality.',
                          icon: Icons.compress_rounded,
                          palette: palette,
                        ),
                        _buildToolCard(
                          context,
                          index: 1,
                          title: 'Vector Editor',
                          description:
                              'Directly select and delete vector graphics, images, and other objects from your PDF.',
                          icon: Icons.shape_line_rounded,
                          palette: palette,
                        ),
                        _buildToolCard(
                          context,
                          index: 2,
                          title: 'Preflight PDF',
                          description:
                              'Check your PDF against quality profiles and fix common issues like page sizes.',
                          icon: Icons.fact_check_rounded,
                          palette: palette,
                        ),
                        _buildToolCard(
                          context,
                          index: 3,
                          title: 'Edit PDF',
                          description:
                              'Directly edit text layers, erase objects, add links, insert images, and run OCR on scanned documents in place.',
                          icon: Icons.edit_note_rounded,
                          palette: palette,
                          isSoon: true,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolCard(
    BuildContext context, {
    required int index,
    required String title,
    required String description,
    required IconData icon,
    required QpicPalette? palette,
    bool isSoon = false,
  }) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final text = palette?.text ?? theme.colorScheme.onSurface;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _currentSubTab = index;
            _errorText = null;
            if (widget.onSubTabChanged != null) {
              widget.onSubTabChanged!(index);
            }
          });
        },
        child: Card(
          color: palette?.panel ?? theme.colorScheme.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: brand.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        color: brand,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: text,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              if (isSoon) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: brand.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Soon',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      color: brand,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: muted.withValues(alpha: 0.7),
                      size: 20,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Text(
                    description,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: muted,
                      height: 1.45,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
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
              style: TextStyle(
                  color: palette?.muted ?? theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_currentSubTab == null) {
      return _buildDashboard(context, palette);
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
              _preflightController!
                  .setFile(bytes: bytes, filename: result.name);
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

    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Back Navigation Bar
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                setState(() {
                  _currentSubTab = null;
                  _errorText = null;
                });
              },
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text(
                'Back to PDF Tools',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: brand,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ),
          const SizedBox(height: 8),

          if (_errorText != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: (palette?.danger ?? theme.colorScheme.error)
                    .withValues(alpha: 0.12),
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

          // Main Layout of the selected tool (headers are rendered by CompressView, EditView, PreflightView themselves)
          Expanded(
            child: subView,
          ),
        ],
      ),
    );
  }
}
