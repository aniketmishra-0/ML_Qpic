// Rename Batch view (Requirements 12.1, 12.2).
//
// [RenameView] renders the Rename Batch controls backed by a
// [RenameController]: naming-pattern input, start number (0–1,000,000),
// zero-padding (0–12), output format (original/png/jpg/jpeg/webp), JPG quality
// (1–100), and a live before/after preview list. On any control change the
// controller calls `POST /api/rename/preview` with the current names, pattern,
// start, and padding (no image bytes) to show the live preview.
//
// This view holds NO engine logic and issues NO requests directly. The
// PDF-to-images and session flow are task 15.2; this view exposes callbacks
// for file picking and the rename action that those tasks wire up.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme_controller.dart';
import '../../models/rename.dart';
import 'rename_controller.dart';

/// Stateless form surface for the Rename Batch tool.
///
/// Listens to [controller] via an [AnimatedBuilder] so every control reflects
/// the controller's clamped state. [errorText] lets the submit path (task 15.2)
/// surface an engine error detail above the form.
class RenameView extends StatelessWidget {
  const RenameView({
    super.key,
    required this.controller,
    this.onPickFiles,
    this.onRename,
    this.errorText,
    this.statusText,
    this.busy = false,
  });

  /// Backing form state.
  final RenameController controller;

  /// Invoked when the user taps the "Add Images" affordance. Wired by the
  /// file-picker integration (task 15.2); when null the affordance is disabled.
  final VoidCallback? onPickFiles;

  /// Invoked when the user taps the "Rename & Download" button. Wired by
  /// task 15.2; when null the button is disabled.
  final VoidCallback? onRename;

  /// Optional error message shown above the form.
  final String? errorText;

  /// Optional transient status line (e.g. "Uploading… 200 / 800") shown near
  /// the file-picker row while a session is in flight.
  final String? statusText;

  /// When true, the Rename button shows a busy state and is disabled.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildForm(context),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(palette: palette),
              const SizedBox(height: 16),
              _FilePickerRow(
                itemCount: controller.itemCount,
                onPickFiles: onPickFiles,
              ),
              if (statusText != null) ...<Widget>[
                const SizedBox(height: 12),
                _StatusLine(message: statusText!, palette: palette),
              ],
              if (errorText != null) ...<Widget>[
                const SizedBox(height: 16),
                _ErrorBanner(message: errorText!, palette: palette),
              ],
              const SizedBox(height: 24),
              _SectionCard(
                title: 'Naming',
                palette: palette,
                children: <Widget>[
                  _PatternField(controller: controller),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _StartField(controller: controller),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _PaddingField(controller: controller),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Output',
                palette: palette,
                children: <Widget>[
                  _OutputFormatSelector(controller: controller),
                  if (controller.outputFormat == RenameOutputFormat.jpg ||
                      controller.outputFormat == RenameOutputFormat.jpeg) ...<Widget>[
                    const SizedBox(height: 16),
                    _JpgQualitySlider(controller: controller),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              _PreviewSection(controller: controller, palette: palette),
              const SizedBox(height: 24),
              _RenameButton(
                busy: busy,
                enabled: controller.itemCount > 0,
                onRename: onRename,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//  Private widgets
// =============================================================================

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
          'Rename Batch',
          key: const ValueKey<String>('rename-title'),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Add images or a PDF, set a naming pattern, then download.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _FilePickerRow extends StatelessWidget {
  const _FilePickerRow({required this.itemCount, required this.onPickFiles});

  final int itemCount;
  final VoidCallback? onPickFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return Row(
      children: <Widget>[
        OutlinedButton.icon(
          key: const ValueKey<String>('rename-pick-files'),
          onPressed: onPickFiles,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Add Images'),
        ),
        const SizedBox(width: 12),
        Text(
          itemCount > 0 ? '$itemCount file${itemCount == 1 ? '' : 's'} loaded' : 'No files added',
          key: const ValueKey<String>('rename-file-count'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: itemCount > 0
                ? (palette?.text ?? theme.colorScheme.onSurface)
                : (palette?.muted ?? theme.colorScheme.onSurfaceVariant),
            fontStyle: itemCount > 0 ? FontStyle.normal : FontStyle.italic,
          ),
        ),
      ],
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
      key: const ValueKey<String>('rename-error'),
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

/// A transient status line shown while a rename session runs (e.g. uploading
/// progress or "Renaming and packing…"). Styled as a muted info chip with a
/// small spinner so it reads as in-progress, not as an error.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.palette});

  final String message;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey<String>('rename-status'),
      children: <Widget>[
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: muted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A titled card grouping related controls.
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
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.4,
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

/// The naming-pattern text field. `#` is the number token; variable tokens
/// like `(name)`, `(width)`, etc. are also supported.
class _PatternField extends StatefulWidget {
  const _PatternField({required this.controller});

  final RenameController controller;

  @override
  State<_PatternField> createState() => _PatternFieldState();
}

class _PatternFieldState extends State<_PatternField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.controller.pattern);

  @override
  void didUpdateWidget(covariant _PatternField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.pattern != _textController.text) {
      _textController.value = TextEditingValue(
        text: widget.controller.pattern,
        selection: TextSelection.collapsed(
          offset: widget.controller.pattern.length,
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
    return TextField(
      key: const ValueKey<String>('rename-pattern'),
      controller: _textController,
      decoration: const InputDecoration(
        labelText: 'Pattern',
        hintText: 'e.g. Q#, (name), page-#',
        helperText: '# = number. Variables: (name), (width), (height), (date), (ext)',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      inputFormatters: <TextInputFormatter>[
        LengthLimitingTextInputFormatter(120),
      ],
      onChanged: (value) => widget.controller.pattern = value,
    );
  }
}

/// Start number field (0–1,000,000).
class _StartField extends StatefulWidget {
  const _StartField({required this.controller});

  final RenameController controller;

  @override
  State<_StartField> createState() => _StartFieldState();
}

class _StartFieldState extends State<_StartField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.controller.start.toString());

  @override
  void didUpdateWidget(covariant _StartField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final parsed = int.tryParse(_textController.text);
    if (parsed != widget.controller.start) {
      final text = widget.controller.start.toString();
      _textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _handleChanged(String raw) {
    if (raw.isEmpty) return;
    final parsed = int.tryParse(raw);
    if (parsed == null) return;
    widget.controller.start = parsed;
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey<String>('rename-start'),
      controller: _textController,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: const InputDecoration(
        labelText: 'Start number',
        helperText: '0–1,000,000',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: _handleChanged,
    );
  }
}

/// Zero-padding field (0–12).
class _PaddingField extends StatefulWidget {
  const _PaddingField({required this.controller});

  final RenameController controller;

  @override
  State<_PaddingField> createState() => _PaddingFieldState();
}

class _PaddingFieldState extends State<_PaddingField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.controller.padding.toString());

  @override
  void didUpdateWidget(covariant _PaddingField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final parsed = int.tryParse(_textController.text);
    if (parsed != widget.controller.padding) {
      final text = widget.controller.padding.toString();
      _textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _handleChanged(String raw) {
    if (raw.isEmpty) return;
    final parsed = int.tryParse(raw);
    if (parsed == null) return;
    widget.controller.padding = parsed;
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey<String>('rename-padding'),
      controller: _textController,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: const InputDecoration(
        labelText: 'Zero-padding',
        helperText: '0–12 digits',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: _handleChanged,
    );
  }
}

/// Output format selector (original/png/jpg/jpeg/webp).
class _OutputFormatSelector extends StatelessWidget {
  const _OutputFormatSelector({required this.controller});

  final RenameController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Output format', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        DropdownButtonFormField<RenameOutputFormat>(
          key: const ValueKey<String>('rename-output-format'),
          initialValue: controller.outputFormat,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<RenameOutputFormat>>[
            for (final format in RenameOutputFormat.values)
              DropdownMenuItem<RenameOutputFormat>(
                value: format,
                child: Text(format.label),
              ),
          ],
          onChanged: (format) {
            if (format != null) controller.outputFormat = format;
          },
        ),
      ],
    );
  }
}

/// JPG quality slider (1–100). Only shown when output format is jpg/jpeg.
class _JpgQualitySlider extends StatelessWidget {
  const _JpgQualitySlider({required this.controller});

  final RenameController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clamped = controller.jpgQuality.clamp(
      RenameBounds.jpgQualityMin,
      RenameBounds.jpgQualityMax,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('JPG quality', style: theme.textTheme.bodyMedium),
            Text(
              '$clamped',
              key: const ValueKey<String>('rename-jpg-quality-value'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          key: const ValueKey<String>('rename-jpg-quality'),
          value: clamped.toDouble(),
          min: RenameBounds.jpgQualityMin.toDouble(),
          max: RenameBounds.jpgQualityMax.toDouble(),
          divisions: RenameBounds.jpgQualityMax - RenameBounds.jpgQualityMin,
          label: '$clamped',
          onChanged: (v) => controller.jpgQuality = v.round(),
        ),
      ],
    );
  }
}

/// Live preview section showing the before/after rename list.
///
/// The before/after pairs are computed client-side ([RenameController.previewPairs])
/// using the web UI's token expansion, so variable tokens like `(name)` and
/// `(width)` render correctly — the engine's `/api/rename/preview` endpoint only
/// understands the `#` number token. The server round-trip (which ships the
/// expanded stems, no image bytes) drives [RenameController.previewError], shown
/// here as a non-blocking banner when the engine reports a problem.
class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.controller, required this.palette});

  final RenameController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (controller.itemCount == 0) {
      return const SizedBox.shrink();
    }

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
            Row(
              children: <Widget>[
                Text(
                  'Preview',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.4,
                  ),
                ),
                if (controller.previewLoading) ...<Widget>[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (controller.previewError != null) ...<Widget>[
              Text(
                controller.previewError!,
                key: const ValueKey<String>('rename-preview-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.danger ?? theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
            ],
            _PreviewList(
              items: controller.previewPairs,
              palette: palette,
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the before/after preview list (client-side computed pairs).
class _PreviewList extends StatelessWidget {
  const _PreviewList({required this.items, required this.palette});

  final List<RenamePlanItem> items;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Show at most 20 items to keep the preview compact.
    final displayItems = items.length > 20 ? items.sublist(0, 20) : items;
    final hasMore = items.length > 20;

    return Column(
      key: const ValueKey<String>('rename-preview-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final item in displayItems)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    item.original,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.arrow_forward,
                    size: 14,
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: Text(
                    item.renamed,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: palette?.text ?? theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '… and ${items.length - 20} more',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

/// The "Rename & Download" button.
class _RenameButton extends StatelessWidget {
  const _RenameButton({
    required this.busy,
    required this.enabled,
    required this.onRename,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const ValueKey<String>('rename-submit'),
      onPressed: busy || !enabled ? null : onRename,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.drive_file_rename_outline),
      label: const Text('Rename & Download ZIP'),
    );
  }
}
