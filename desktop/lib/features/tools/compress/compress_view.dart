// Compress panel view (Requirement 13).
//
// [CompressView] renders the Compress tool backed by a [CompressController]:
//   * a PDF picker + drag-and-drop zone (Requirements 17/18 plumbing),
//   * a level selector offering light / balanced / strong / extreme
//     (Requirement 13.1),
//   * an optional "target a file size" toggle + MB field constrained to values
//     greater than 0 (Requirement 13.1),
//   * a Compress button that runs the engine job (Requirement 13.2),
//   * a result block showing original_size, compressed_size and the ratio with
//     a Download action (Requirements 13.3, 13.4), and
//   * an inline error banner that surfaces the engine `detail` (Requirement
//     13.5).
//
// This view holds NO engine logic and issues NO requests directly — every
// action delegates to the [CompressController]. Every interactive widget
// carries a stable `ValueKey` so widget tests (task 18.3) can drive it.

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme_controller.dart';
import '../../../models/crop.dart';
import '../../../widgets/drop_target.dart';
import '../../../widgets/pdf_preview_dialog.dart';
import 'compress_controller.dart';

/// Stateless surface for the Compress tool. Listens to [controller] so every
/// control reflects its state; [onPickFile] is wired to the native picker by
/// the host (the view does not own file I/O).
class CompressView extends StatelessWidget {
  const CompressView({
    super.key,
    required this.controller,
    this.onPickFile,
  });

  /// Backing panel state. The view never mutates anything other than this.
  final CompressController controller;

  /// Invoked when the user taps "Choose PDF". When null the affordance is
  /// disabled (the drop target still works).
  final VoidCallback? onPickFile;

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool wide = constraints.maxWidth >= 900;

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 380,
                child: Material(
                  color: palette?.panel ?? theme.colorScheme.surface,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _Header(palette: palette),
                        const SizedBox(height: 24),
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
                        const SizedBox(height: 32),
                        _SectionCard(
                          title: 'Compression level',
                          palette: palette,
                          children: <Widget>[
                            _LevelSelector(controller: controller),
                            const SizedBox(height: 16),
                            _TargetSizeSection(controller: controller),
                          ],
                        ),
                        const SizedBox(height: 32),
                        _CompressButton(controller: controller),
                      ],
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Container(
                  color: palette?.background ?? theme.colorScheme.surface,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: controller.result != null
                          ? ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: _ResultCard(
                                  controller: controller, palette: palette),
                            )
                          : ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 500),
                              child: _ResultPlaceholder(palette: palette),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

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
                  _SectionCard(
                    title: 'Compression level',
                    palette: palette,
                    children: <Widget>[
                      _LevelSelector(controller: controller),
                      const SizedBox(height: 16),
                      _TargetSizeSection(controller: controller),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _CompressButton(controller: controller),
                  if (controller.result != null) ...<Widget>[
                    const SizedBox(height: 24),
                    _ResultCard(controller: controller, palette: palette),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ResultPlaceholder extends StatelessWidget {
  const _ResultPlaceholder({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final border = palette?.border ?? theme.dividerColor;

    return Card(
      color: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.compress_rounded,
              size: 64,
              color: muted.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 24),
            Text(
              'Waiting for PDF',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: palette?.text ?? theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Select a PDF and choose a compression level on the left.\nThe optimization results and download options will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: muted,
                height: 1.5,
              ),
            ),
          ],
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
          'Compress PDF',
          key: const ValueKey<String>('compress-title'),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Shrink a PDF by a quality level or to a target size, then download.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A PDF-only drop zone with a "Choose PDF" affordance and the selected
/// filename. Dropping or picking a PDF loads it into the controller.
class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.controller,
    required this.onPickFile,
    required this.palette,
  });

  final CompressController controller;
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
      key: const ValueKey<String>('compress-drop-target'),
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
                key: const ValueKey<String>('compress-pick-file'),
                onPressed: onPickFile,
                icon: const Icon(Icons.upload_file),
                label: const Text('Choose PDF'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.fileName ?? 'Drop a PDF here or click to browse',
                  key: const ValueKey<String>('compress-file-name'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: controller.fileName == null
                        ? (palette?.muted ?? theme.colorScheme.onSurfaceVariant)
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
                  key: const ValueKey<String>('compress-clear'),
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
      key: const ValueKey<String>('compress-error'),
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

/// A titled card grouping related controls (mirrors the Auto Crop view).
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    required this.palette,
  });

  final String title;
  final List<Widget> children;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// The light / balanced / strong / extreme level selector (Requirement 13.1).
///
/// Rendered as a column of selectable cards (the web UI's level grid). The
/// whole group is dimmed and disabled while target mode is on, since the engine
/// ignores `level` then (Requirement 13.2).
class _LevelSelector extends StatelessWidget {
  const _LevelSelector({required this.controller});

  final CompressController controller;

  @override
  Widget build(BuildContext context) {
    final disabled = controller.useTarget;
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: IgnorePointer(
        ignoring: disabled,
        child: Column(
          key: const ValueKey<String>('compress-levels'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final level in CompressLevel.values) ...<Widget>[
              _LevelCard(
                level: level,
                selected: controller.level == level,
                onTap: () => controller.level = level,
              ),
              if (level != CompressLevel.values.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({
    required this.level,
    required this.selected,
    required this.onTap,
  });

  final CompressLevel level;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final accent = palette?.brand ?? theme.colorScheme.primary;
    final border = palette?.border ?? theme.dividerColor;

    return InkWell(
      key: ValueKey<String>('compress-level-${level.value}'),
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? accent : border,
            width: selected ? 2 : 1,
          ),
          color: selected ? accent.withAlpha(20) : Colors.transparent,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected
                  ? accent
                  : (palette?.muted ?? theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    level.label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: palette?.text ?? theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    level.blurb,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                    ),
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

/// The "target a file size" toggle plus the MB field (Requirement 13.1). The
/// field is shown only when the toggle is on, and an inline hint flags an
/// invalid (≤ 0 or non-numeric) entry.
class _TargetSizeSection extends StatelessWidget {
  const _TargetSizeSection({required this.controller});

  final CompressController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          key: const ValueKey<String>('compress-target-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Target a file size'),
          subtitle: const Text(
            'Push quality down until the PDF fits a size you choose '
            '(overrides level).',
          ),
          value: controller.useTarget,
          onChanged: (value) => controller.useTarget = value,
        ),
        if (controller.useTarget) ...<Widget>[
          const SizedBox(height: 8),
          _TargetMbField(controller: controller),
        ],
      ],
    );
  }
}

class _TargetMbField extends StatefulWidget {
  const _TargetMbField({required this.controller});

  final CompressController controller;

  @override
  State<_TargetMbField> createState() => _TargetMbFieldState();
}

class _TargetMbFieldState extends State<_TargetMbField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.controller.targetMbText);

  @override
  void didUpdateWidget(covariant _TargetMbField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.targetMbText != _textController.text) {
      _textController.value = TextEditingValue(
        text: widget.controller.targetMbText,
        selection: TextSelection.collapsed(
          offset: widget.controller.targetMbText.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final invalid =
        widget.controller.useTarget && !widget.controller.isTargetValid;
    return TextField(
      key: const ValueKey<String>('compress-target-mb'),
      controller: _textController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: <TextInputFormatter>[
        // Digits and a single decimal point (no sign — target must be > 0).
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: 'Target size (MB)',
        hintText: 'e.g. 2',
        helperText: 'Must be greater than 0.',
        errorText: invalid ? 'Enter a size greater than 0.' : null,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) => widget.controller.targetMbText = value,
    );
  }
}

class _CompressButton extends StatelessWidget {
  const _CompressButton({required this.controller});

  final CompressController controller;

  @override
  Widget build(BuildContext context) {
    final busy = controller.busy;
    return FilledButton.icon(
      key: const ValueKey<String>('compress-submit'),
      onPressed: controller.canRun ? () => controller.compress() : null,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.compress),
      label: Text(busy ? 'Compressing…' : 'Compress PDF'),
    );
  }
}

/// The result block: percent-smaller headline, before/after sizes + mode, any
/// engine note / target outcome, and the Download action (Requirements 13.3,
/// 13.4).
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.controller, required this.palette});

  final CompressController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = controller.result!;
    final pct = controller.percentSmaller ?? 0;
    final success = palette?.success ?? theme.colorScheme.primary;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '$pct% smaller',
              key: const ValueKey<String>('compress-result-ratio'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: success,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: <Widget>[
                _Stat(
                  label: 'Before',
                  value: humanFileSize(result.originalSize),
                  valueKey: const ValueKey<String>('compress-result-original'),
                  palette: palette,
                ),
                _Stat(
                  label: 'After',
                  value: humanFileSize(result.compressedSize),
                  valueKey:
                      const ValueKey<String>('compress-result-compressed'),
                  palette: palette,
                ),
                _Stat(
                  label: 'Mode',
                  value: result.level,
                  valueKey: const ValueKey<String>('compress-result-mode'),
                  palette: palette,
                ),
              ],
            ),
            if (result.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                result.note,
                key: const ValueKey<String>('compress-result-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (result.targetMet != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                result.targetMet == true
                    ? '✓ Reached your target size.'
                    : "⚠ Couldn't fully reach your target without harming "
                        'readability — this is the smallest safe result.',
                key: const ValueKey<String>('compress-result-target'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: result.targetMet == true
                      ? success
                      : (palette?.warn ?? theme.colorScheme.tertiary),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey<String>('compress-download'),
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
                    key: const ValueKey<String>('compress-view'),
                    onPressed: controller.result != null
                        ? () => _viewCompressedPdf(context)
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

  void _viewCompressedPdf(BuildContext context) {
    final response = controller.result;
    if (response == null) return;

    final pages = response.pages
        .map((p) => PageInfo(
              page: p.page,
              widthPt: p.width,
              heightPt: p.height,
              previewUrl: p.previewUrl,
            ))
        .toList();

    PdfPreviewDialog.open(
      context,
      title: controller.fileName ?? 'compressed.pdf',
      pages: pages,
      resolveUrl: (url) => controller.apiClient.resolveUri(url).toString(),
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
