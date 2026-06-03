// Preflight panel view (Requirement 14).
//
// [PreflightView] renders the Preflight tool backed by a [PreflightController]:
//   * a PDF picker + drag-and-drop zone (Requirements 17/18 plumbing),
//   * a Run Preflight button that runs the engine inspection (Req 14.1),
//   * a result block showing verdict, page_count, page_sizes, checks, fonts,
//     images, and page_details (Req 14.2),
//   * when mixed_page_sizes is true, a one-click Fix action with target,
//     fill_mode, and skip_pages controls (Req 14.3, 14.4),
//   * a download action for the normalized PDF (Req 14.5), and
//   * an inline error banner that surfaces the engine `detail` (Req 14.6).
//
// This view holds NO engine logic and issues NO requests directly — every
// action delegates to the [PreflightController]. Every interactive widget
// carries a stable `ValueKey` so widget tests (task 18.3) can drive it.

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';

import '../../../core/theme_controller.dart';
import '../../../models/crop.dart';
import '../../../models/tools.dart';
import '../../../widgets/drop_target.dart';
import '../../../widgets/pdf_preview_dialog.dart';
import 'preflight_controller.dart';

/// Stateless surface for the Preflight tool. Listens to [controller] so every
/// control reflects its state; [onPickFile] is wired to the native picker by
/// the host (the view does not own file I/O).
class PreflightView extends StatelessWidget {
  const PreflightView({
    super.key,
    required this.controller,
    this.onPickFile,
    this.initiallyExpanded = false,
  });

  /// Backing panel state. The view never mutates anything other than this.
  final PreflightController controller;

  /// Invoked when the user taps "Choose PDF". When null the affordance is
  /// disabled (the drop target still works).
  final VoidCallback? onPickFile;

  /// Whether collapsible lists should be expanded by default (useful in tests).
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildPanel(context),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(palette: palette),
              const SizedBox(height: 16),
              _DropZone(
                controller: controller,
                onPickFile: onPickFile,
                palette: palette,
              ),
              if (controller.errorText != null) ...<Widget>[
                const SizedBox(height: 16),
                _ErrorBanner(
                    message: controller.errorText!, palette: palette),
              ],
              const SizedBox(height: 24),
              _PreflightButton(controller: controller),
              if (controller.result != null) ...<Widget>[
                const SizedBox(height: 24),
                _ResultCard(
                  controller: controller,
                  palette: palette,
                  initiallyExpanded: initiallyExpanded,
                ),
              ],
              if (controller.fixResult != null) ...<Widget>[
                const SizedBox(height: 24),
                _FixResultCard(controller: controller, palette: palette),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Preflight Check',
          key: const ValueKey<String>('preflight-title'),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Inspect a PDF for print-readiness and optionally normalize '
          'mixed page sizes.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A PDF-only drop zone with a "Choose PDF" affordance and the selected
/// filename.
class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.controller,
    required this.onPickFile,
    required this.palette,
  });

  final PreflightController controller;
  final VoidCallback? onPickFile;
  final QpicPalette? palette;

  Future<void> _loadXFile(XFile file) async {
    final bytes = await file.readAsBytes();
    final name = file.name.isNotEmpty ? file.name : 'document.pdf';
    controller.setFile(bytes: bytes, filename: name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropFileTarget.pdfOnly(
      key: const ValueKey<String>('preflight-drop-target'),
      onAccepted: (files) {
        if (files.isNotEmpty) _loadXFile(files.first);
      },
      onRejected: (message) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
      child: Material(
        color: palette?.panel ?? theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette?.border ?? theme.dividerColor),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              OutlinedButton.icon(
                key: const ValueKey<String>('preflight-pick-file'),
                onPressed: onPickFile,
                icon: const Icon(Icons.upload_file),
                label: const Text('Choose PDF'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.fileName ??
                      'Drop a PDF here or click to browse',
                  key: const ValueKey<String>('preflight-file-name'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: controller.fileName == null
                        ? (palette?.muted ??
                            theme.colorScheme.onSurfaceVariant)
                        : (palette?.text ?? theme.colorScheme.onSurface),
                    fontStyle: controller.fileName == null
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ),
              if (controller.hasFile) ...[
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey<String>('preflight-clear'),
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear selection',
                  onPressed: () => controller.clear(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.palette});

  final String message;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = palette?.danger ?? theme.colorScheme.error;
    return Container(
      key: const ValueKey<String>('preflight-error'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: danger.withAlpha(28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: danger.withAlpha(120)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: danger, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreflightButton extends StatelessWidget {
  const _PreflightButton({required this.controller});

  final PreflightController controller;

  @override
  Widget build(BuildContext context) {
    final busy = controller.busy;
    return FilledButton.icon(
      key: const ValueKey<String>('preflight-submit'),
      onPressed: controller.canRun ? () => controller.runPreflight() : null,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.checklist),
      label: Text(busy ? 'Inspecting…' : 'Run Preflight'),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.controller,
    required this.palette,
    required this.initiallyExpanded,
  });

  final PreflightController controller;
  final QpicPalette? palette;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = controller.result!;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette?.border ?? theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _VerdictRow(
              verdict: result.verdict,
              palette: palette,
              onViewPdf: () => _viewOriginalPdf(context),
            ),
            const SizedBox(height: 16),
            _SummaryStats(result: result, palette: palette),
            const SizedBox(height: 16),
            _ChecksList(checks: result.checks, palette: palette),
            if (result.fonts.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _FontsList(
                fonts: result.fonts,
                palette: palette,
                initiallyExpanded: initiallyExpanded,
              ),
            ],
            if (result.images.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _ImagesList(
                images: result.images,
                palette: palette,
                initiallyExpanded: initiallyExpanded,
              ),
            ],
            if (result.pageDetails.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _PageDetailsList(
                pageDetails: result.pageDetails,
                palette: palette,
                initiallyExpanded: initiallyExpanded,
              ),
            ],
            if (result.mixedPageSizes) ...<Widget>[
              const SizedBox(height: 24),
              _FixPageSizesSection(
                  controller: controller, palette: palette),
            ],
          ],
        ),
      ),
    );
  }

  void _viewOriginalPdf(BuildContext context) {
    final res = controller.result;
    if (res == null || res.jobId == null) return;

    final pages = res.pages
        .map((p) => PageInfo(
              page: p.page,
              widthPt: p.width,
              heightPt: p.height,
              previewUrl: p.previewUrl,
            ))
        .toList();

    PdfPreviewDialog.open(
      context,
      title: controller.fileName ?? 'preflight.pdf',
      pages: pages,
      resolveUrl: (url) => controller.apiClient.resolveUri(url).toString(),
    );
  }
}

class _VerdictRow extends StatelessWidget {
  const _VerdictRow({
    required this.verdict,
    required this.palette,
    this.onViewPdf,
  });

  final String verdict;
  final QpicPalette? palette;
  final VoidCallback? onViewPdf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color color;
    IconData icon;
    switch (verdict) {
      case 'pass':
        color = palette?.success ?? Colors.green;
        icon = Icons.check_circle;
        break;
      case 'warn':
        color = palette?.warn ?? Colors.orange;
        icon = Icons.warning;
        break;
      default:
        color = palette?.danger ?? theme.colorScheme.error;
        icon = Icons.cancel;
    }
    return Row(
      children: <Widget>[
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 8),
        Text(
          verdict.toUpperCase(),
          key: const ValueKey<String>('preflight-verdict'),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        if (onViewPdf != null) ...[
          const Spacer(),
          OutlinedButton.icon(
            key: const ValueKey<String>('preflight-view-original'),
            onPressed: onViewPdf,
            icon: const Icon(Icons.visibility),
            label: const Text('View PDF'),
          ),
        ],
      ],
    );
  }
}

class _SummaryStats extends StatelessWidget {
  const _SummaryStats({required this.result, required this.palette});

  final PreflightResponse result;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: <Widget>[
        _Stat(
          label: 'Pages',
          value: result.pageCount.toString(),
          valueKey: const ValueKey<String>('preflight-page-count'),
          palette: palette,
        ),
        _Stat(
          label: 'Page sizes',
          value: result.distinctPageSizes.isNotEmpty
              ? result.distinctPageSizes.join(', ')
              : result.pageSizes.join(', '),
          valueKey: const ValueKey<String>('preflight-page-sizes'),
          palette: palette,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.valueKey,
    required this.palette,
  });

  final String label;
  final String value;
  final Key valueKey;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          key: valueKey,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _ChecksList extends StatelessWidget {
  const _ChecksList({required this.checks, required this.palette});

  final List<PreflightCheckModel> checks;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey<String>('preflight-checks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Checks',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (final check in checks)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _checkIcon(check.status, theme),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        check.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: palette?.text ??
                              theme.colorScheme.onSurface,
                        ),
                      ),
                      if (check.detail.isNotEmpty)
                        Text(
                          check.detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette?.muted ??
                                theme.colorScheme.onSurfaceVariant,
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

  Widget _checkIcon(String status, ThemeData theme) {
    switch (status) {
      case 'ok':
        return Icon(Icons.check_circle_outline,
            color: palette?.success ?? Colors.green, size: 18);
      case 'warn':
        return Icon(Icons.warning_amber,
            color: palette?.warn ?? Colors.orange, size: 18);
      case 'fail':
        return Icon(Icons.cancel_outlined,
            color: palette?.danger ?? theme.colorScheme.error, size: 18);
      default:
        return Icon(Icons.info_outline,
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            size: 18);
    }
  }
}

class _FontsList extends StatelessWidget {
  const _FontsList({
    required this.fonts,
    required this.palette,
    required this.initiallyExpanded,
  });

  final List<PreflightFontModel> fonts;
  final QpicPalette? palette;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CollapsibleSection(
      title: 'Fonts (${fonts.length})',
      palette: palette,
      initiallyExpanded: initiallyExpanded,
      child: Column(
        key: const ValueKey<String>('preflight-fonts'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final font in fonts)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      font.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette?.text ??
                            theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    font.type,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette?.muted ??
                          theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (font.embedded)
                    Icon(Icons.check, size: 16,
                        color: palette?.success ?? Colors.green)
                  else
                    Icon(Icons.close, size: 16,
                        color: palette?.warn ?? Colors.orange),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ImagesList extends StatelessWidget {
  const _ImagesList({
    required this.images,
    required this.palette,
    required this.initiallyExpanded,
  });

  final List<PreflightImageModel> images;
  final QpicPalette? palette;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CollapsibleSection(
      title: 'Images (${images.length})',
      palette: palette,
      initiallyExpanded: initiallyExpanded,
      child: Column(
        key: const ValueKey<String>('preflight-images'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final img in images)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Page ${img.page}: ${img.width}×${img.height} '
                '${img.colorspace} ${img.dpi.toStringAsFixed(0)} DPI '
                '(${img.bpc} bpc)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.text ?? theme.colorScheme.onSurface,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PageDetailsList extends StatelessWidget {
  const _PageDetailsList({
    required this.pageDetails,
    required this.palette,
    required this.initiallyExpanded,
  });

  final List<PreflightPageDetail> pageDetails;
  final QpicPalette? palette;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CollapsibleSection(
      title: 'Page Details (${pageDetails.length})',
      palette: palette,
      initiallyExpanded: initiallyExpanded,
      child: Column(
        key: const ValueKey<String>('preflight-page-details'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final pd in pageDetails)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Page ${pd.page}: ${pd.format} ${pd.orientation} '
                '(${pd.wMm.toStringAsFixed(1)}×'
                '${pd.hMm.toStringAsFixed(1)} mm)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.text ?? theme.colorScheme.onSurface,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The "Fix page sizes" section shown when mixed_page_sizes is true
/// (Req 14.3, 14.4). Offers target, fill_mode, skip_pages controls and a
/// one-click Fix button.
class _FixPageSizesSection extends StatelessWidget {
  const _FixPageSizesSection({
    required this.controller,
    required this.palette,
  });

  final PreflightController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = palette?.warn ?? Colors.orange;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: warn.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: warn.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.warning_amber, color: warn, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mixed page sizes detected',
                  key: const ValueKey<String>(
                      'preflight-mixed-warning'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette?.text ??
                        theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _TargetField(controller: controller),
          const SizedBox(height: 12),
          _FillModeSelector(controller: controller),
          const SizedBox(height: 12),
          _SkipPagesField(controller: controller),
          const SizedBox(height: 16),
          _FixButton(controller: controller),
        ],
      ),
    );
  }
}

class _TargetField extends StatelessWidget {
  const _TargetField({required this.controller});

  final PreflightController controller;

  @override
  Widget build(BuildContext context) {
    // Offer the distinct page sizes from the result plus "auto" as options.
    final result = controller.result;
    final options = <String>['auto'];
    if (result != null) {
      for (final size in result.distinctPageSizes) {
        if (!options.contains(size)) options.add(size);
      }
    }

    return DropdownButtonFormField<String>(
      key: const ValueKey<String>('preflight-fix-target'),
      initialValue: options.contains(controller.target)
          ? controller.target
          : 'auto',
      decoration: const InputDecoration(
        labelText: 'Target page size',
        helperText: '"auto" uses the most common size in the PDF.',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: options
          .map((s) => DropdownMenuItem(value: s, child: Text(s)))
          .toList(),
      onChanged: (value) {
        if (value != null) controller.target = value;
      },
    );
  }
}

class _FillModeSelector extends StatelessWidget {
  const _FillModeSelector({required this.controller});

  final PreflightController controller;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<FillMode>(
      groupValue: controller.fillMode,
      onChanged: (value) {
        if (value != null) controller.fillMode = value;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final mode in FillMode.values)
            RadioListTile<FillMode>(
              key: ValueKey<String>('preflight-fill-${mode.value}'),
              title: Text(mode.label),
              subtitle: Text(mode.description),
              value: mode,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
        ],
      ),
    );
  }
}

class _SkipPagesField extends StatelessWidget {
  const _SkipPagesField({required this.controller});

  final PreflightController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey<String>('preflight-fix-skip-pages'),
      decoration: const InputDecoration(
        labelText: 'Skip pages',
        hintText: 'e.g. 1,3,5',
        helperText: 'Comma-separated page numbers to leave unchanged.',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: (value) => controller.skipPages = value,
    );
  }
}

class _FixButton extends StatelessWidget {
  const _FixButton({required this.controller});

  final PreflightController controller;

  @override
  Widget build(BuildContext context) {
    final fixing = controller.fixing;
    return FilledButton.icon(
      key: const ValueKey<String>('preflight-fix-submit'),
      onPressed:
          controller.canFix ? () => controller.fixPageSizes() : null,
      icon: fixing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.build),
      label: Text(fixing ? 'Fixing…' : 'Fix page sizes'),
    );
  }
}

/// The fix result card: shows the normalization outcome and a Download action
/// (Requirement 14.5).
class _FixResultCard extends StatelessWidget {
  const _FixResultCard({required this.controller, required this.palette});

  final PreflightController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fixResult = controller.fixResult!;
    final success = palette?.success ?? theme.colorScheme.primary;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette?.border ?? theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Page sizes normalized',
              key: const ValueKey<String>('preflight-fix-result-title'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: success,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: <Widget>[
                _Stat(
                  label: 'Target',
                  value: fixResult.targetLabel,
                  valueKey: const ValueKey<String>(
                      'preflight-fix-target-label'),
                  palette: palette,
                ),
                _Stat(
                  label: 'Pages changed',
                  value:
                      '${fixResult.pagesChanged} / ${fixResult.pagesTotal}',
                  valueKey: const ValueKey<String>(
                      'preflight-fix-pages-changed'),
                  palette: palette,
                ),
              ],
            ),
            if (fixResult.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                fixResult.note,
                key: const ValueKey<String>('preflight-fix-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.muted ??
                      theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey<String>('preflight-fix-download'),
                    onPressed: controller.canDownload
                        ? () => controller.download()
                        : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Download PDF'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey<String>('preflight-fix-view'),
                    onPressed: controller.fixResult != null
                        ? () => _viewFixedPdf(context)
                        : null,
                    icon: const Icon(Icons.visibility),
                    label: const Text('View'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _viewFixedPdf(BuildContext context) {
    final fixResult = controller.fixResult;
    if (fixResult == null) return;

    final pages = fixResult.pages
        .map((p) => PageInfo(
              page: p.page,
              widthPt: p.width,
              heightPt: p.height,
              previewUrl: p.previewUrl,
            ))
        .toList();

    PdfPreviewDialog.open(
      context,
      title: 'normalized_${controller.fileName ?? "fixed.pdf"}',
      pages: pages,
      resolveUrl: (url) => controller.apiClient.resolveUri(url).toString(),
    );
  }
}

class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection({
    required this.title,
    required this.child,
    required this.palette,
    this.initiallyExpanded = false,
  });

  final String title;
  final Widget child;
  final QpicPalette? palette;
  final bool initiallyExpanded;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: widget.palette?.text ?? theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: widget.palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          widget.child,
        ],
      ],
    );
  }
}
