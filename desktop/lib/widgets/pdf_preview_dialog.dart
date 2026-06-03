// A lightweight in-app PDF preview popup.
//
// [PdfPreviewDialog] shows the engine-rendered page images for an already
// selected PDF in a scrollable, zoomable dialog — so the user can eyeball the
// document without leaving the tool. It holds NO engine logic: the host fetches
// the page previews (via `POST /api/prepare-manual`, which rasterises every
// page) and passes the resulting [PageInfo] list plus a URL resolver that joins
// each page's `preview_url` onto the live Base_URL.

import 'package:flutter/material.dart';

import '../core/theme_controller.dart';
import '../models/crop.dart';

/// Resolves an engine `preview_url` to an absolute URL string (typically
/// `ApiClient.resolveUri(url).toString()`).
typedef PreviewUrlResolver = String Function(String previewUrl);

/// A modal dialog that previews the pages of a PDF as images.
class PdfPreviewDialog extends StatefulWidget {
  const PdfPreviewDialog({
    super.key,
    required this.title,
    required this.pages,
    required this.resolveUrl,
  });

  /// Shown in the dialog header (typically the PDF filename).
  final String title;

  /// The rendered pages to display, in order.
  final List<PageInfo> pages;

  /// Joins each page's engine `preview_url` onto the live Base_URL.
  final PreviewUrlResolver resolveUrl;

  /// Opens the dialog. A convenience wrapper around [showDialog].
  static Future<void> open(
    BuildContext context, {
    required String title,
    required List<PageInfo> pages,
    required PreviewUrlResolver resolveUrl,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => PdfPreviewDialog(
        title: title,
        pages: pages,
        resolveUrl: resolveUrl,
      ),
    );
  }

  @override
  State<PdfPreviewDialog> createState() => _PdfPreviewDialogState();
}

class _PdfPreviewDialogState extends State<PdfPreviewDialog> {
  // Page width scale, stepped by the zoom controls.
  static const double _minZoom = 0.5;
  static const double _maxZoom = 2.5;
  double _zoom = 1.0;

  void _zoomIn() =>
      setState(() => _zoom = (_zoom + 0.25).clamp(_minZoom, _maxZoom));
  void _zoomOut() =>
      setState(() => _zoom = (_zoom - 0.25).clamp(_minZoom, _maxZoom));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final size = MediaQuery.of(context).size;

    final Color panel = palette?.panel ?? theme.colorScheme.surface;
    final Color border = palette?.border ?? theme.dividerColor;
    final Color text = palette?.text ?? theme.colorScheme.onSurface;
    final Color muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final Color brand = palette?.brand ?? theme.colorScheme.primary;

    return Dialog(
      key: const ValueKey<String>('pdf-preview-dialog'),
      backgroundColor: panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(28),
      child: SizedBox(
        width: size.width * 0.7,
        height: size.height * 0.86,
        child: Column(
          children: <Widget>[
            _Header(
              title: widget.title,
              pageCount: widget.pages.length,
              text: text,
              muted: muted,
              brand: brand,
              border: border,
              onZoomIn: _zoom < _maxZoom ? _zoomIn : null,
              onZoomOut: _zoom > _minZoom ? _zoomOut : null,
              zoomLabel: '${(_zoom * 100).round()}%',
            ),
            Expanded(
              child: widget.pages.isEmpty
                  ? Center(
                      child: Text(
                        'This PDF has no pages to preview.',
                        style: TextStyle(color: muted),
                      ),
                    )
                  : _PageList(
                      pages: widget.pages,
                      resolveUrl: widget.resolveUrl,
                      zoom: _zoom,
                      muted: muted,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.pageCount,
    required this.text,
    required this.muted,
    required this.brand,
    required this.border,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.zoomLabel,
  });

  final String title;
  final int pageCount;
  final Color text;
  final Color muted;
  final Color brand;
  final Color border;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final String zoomLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.picture_as_pdf_rounded, color: brand, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$pageCount page${pageCount == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('pdf-preview-zoom-out'),
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
            icon: const Icon(Icons.zoom_out_rounded),
            color: muted,
          ),
          SizedBox(
            width: 48,
            child: Text(
              zoomLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('pdf-preview-zoom-in'),
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
            icon: const Icon(Icons.zoom_in_rounded),
            color: muted,
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey<String>('pdf-preview-close'),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close_rounded),
            color: muted,
          ),
        ],
      ),
    );
  }
}

class _PageList extends StatefulWidget {
  const _PageList({
    required this.pages,
    required this.resolveUrl,
    required this.zoom,
    required this.muted,
  });

  final List<PageInfo> pages;
  final PreviewUrlResolver resolveUrl;
  final double zoom;
  final Color muted;

  @override
  State<_PageList> createState() => _PageListState();
}

class _PageListState extends State<_PageList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Base page width fills most of the viewport; the zoom scale steps it
        // up/down. Clamp so a wide window doesn't blow the image up past 1:1.
        final double baseWidth =
            (constraints.maxWidth - 48).clamp(280.0, 900.0).toDouble();
        final double pageWidth = baseWidth * widget.zoom;

        return Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: ListView.separated(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            itemCount: widget.pages.length,
            separatorBuilder: (_, __) => const SizedBox(height: 20),
            itemBuilder: (context, index) {
              final page = widget.pages[index];
              final aspect = page.heightPt > 0 && page.widthPt > 0
                  ? page.heightPt / page.widthPt
                  : 1.414; // A4 fallback
              final url = widget.resolveUrl(page.previewUrl);

              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: pageWidth,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: AspectRatio(
                        aspectRatio: 1 / aspect,
                        child: Image.network(
                          url,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            );
                          },
                          errorBuilder: (context, error, stack) => Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Could not load page ${page.page}.',
                                style: const TextStyle(color: Colors.black54),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Page ${page.page}',
                      style: TextStyle(fontSize: 11.5, color: widget.muted),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
