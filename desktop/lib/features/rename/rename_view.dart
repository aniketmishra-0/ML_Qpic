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
    this.onPickFolder,
    this.onRename,
    this.onClear,
    this.errorText,
    this.statusText,
    this.busy = false,
  });

  /// Backing form state.
  final RenameController controller;

  /// Invoked when the user taps the "Add Images" affordance. Wired by the
  /// file-picker integration (task 15.2); when null the affordance is disabled.
  final VoidCallback? onPickFiles;

  /// Invoked when the user taps the "Add Folder" affordance. Picks a directory
  /// and loads all image/PDF files from it. Workaround for macOS CMD+A issue.
  final VoidCallback? onPickFolder;

  /// Invoked when the user taps the "Rename & Download" button. Wired by
  /// task 15.2; when null the button is disabled.
  final VoidCallback? onRename;

  /// Invoked when the user taps "Clear" to reset the tool back to its defaults
  /// (drops all loaded files and restores the naming controls). Typically wired
  /// to [RenameController.reset]. When null the affordance is hidden.
  final VoidCallback? onClear;

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

    // Full-bleed layout: spans the whole tool area (no narrow centered column
    // with empty side margins). On a wide window the naming/output controls sit
    // on the left and the live preview fills the right, each scrolling
    // independently only if its own content overflows — so the page itself
    // never needs to scroll. A narrow window collapses to a single scrolling
    // column.
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool wide = constraints.maxWidth >= 880;
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _HeaderBar(
                palette: palette,
                onClear: onClear,
                busy: busy,
              ),
              const SizedBox(height: 16),
              _FilePickerRow(
                itemCount: controller.itemCount,
                onPickFiles: onPickFiles,
                onPickFolder: onPickFolder,
              ),
              if (statusText != null) ...<Widget>[
                const SizedBox(height: 12),
                _StatusLine(message: statusText!, palette: palette),
              ],
              if (errorText != null) ...<Widget>[
                const SizedBox(height: 14),
                _ErrorBanner(message: errorText!, palette: palette),
              ],
              const SizedBox(height: 18),
              Expanded(
                child: wide
                    ? _buildWideBody(context, palette)
                    : _buildNarrowBody(context, palette),
              ),
              if (controller.itemCount > 0) ...<Widget>[
                const SizedBox(height: 16),
                _ImageGalleryRow(controller: controller, palette: palette),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Two-column body for wide windows: naming + output controls on the left,
  /// the live preview on the right.
  Widget _buildWideBody(BuildContext context, QpicPalette? palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              flex: 3,
              child: _SectionCard(
                title: 'Naming',
                palette: palette,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        flex: 3,
                        child: _PatternField(controller: controller),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: _StartField(controller: controller),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: _PaddingField(controller: controller),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: _SectionCard(
                title: 'Output',
                palette: palette,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: _OutputFormatSelector(controller: controller),
                      ),
                      if (controller.outputFormat == RenameOutputFormat.jpg ||
                          controller.outputFormat ==
                              RenameOutputFormat.jpeg) ...<Widget>[
                        const SizedBox(width: 16),
                        Expanded(
                          child: _JpgQualitySlider(controller: controller),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _RenameButton(
          busy: busy,
          enabled: controller.itemCount > 0,
          onRename: onRename,
          itemCount: controller.itemCount,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _PreviewSection(controller: controller, palette: palette),
        ),
      ],
    );
  }

  /// Single-column body for narrow windows. Scrolls as a fallback so the form
  /// stays usable when there isn't room for the side-by-side preview.
  Widget _buildNarrowBody(BuildContext context, QpicPalette? palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionCard(
          title: 'Naming',
          palette: palette,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: _PatternField(controller: controller),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: _StartField(controller: controller),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: _PaddingField(controller: controller),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Output',
          palette: palette,
          children: <Widget>[
            _OutputFormatSelector(controller: controller),
            if (controller.outputFormat == RenameOutputFormat.jpg ||
                controller.outputFormat ==
                    RenameOutputFormat.jpeg) ...<Widget>[
              const SizedBox(height: 12),
              _JpgQualitySlider(controller: controller),
            ],
          ],
        ),
        const SizedBox(height: 12),
        _RenameButton(
          busy: busy,
          enabled: controller.itemCount > 0,
          onRename: onRename,
          itemCount: controller.itemCount,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _PreviewSection(controller: controller, palette: palette),
        ),
      ],
    );
  }
}

// =============================================================================
//  Private widgets
// =============================================================================

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.palette,
    required this.onClear,
    required this.busy,
  });

  final QpicPalette? palette;
  final VoidCallback? onClear;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Rename Batch',
                key: const ValueKey<String>('rename-title'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Add images or a PDF, set a naming pattern, then download.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (onClear != null) ...<Widget>[
          const SizedBox(width: 16),
          TextButton.icon(
            key: const ValueKey<String>('rename-clear'),
            onPressed: busy ? null : onClear,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Clear'),
            style: TextButton.styleFrom(
              foregroundColor:
                  palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// File picker styled as a horizontal drop zone to match the Auto Crop and
/// Manual Crop tools. The icon + count sit on the left; the Add Images / Add
/// Folder actions sit on the right so every tool presents the same file
/// affordance instead of three different blocks.
class _FilePickerRow extends StatelessWidget {
  const _FilePickerRow({required this.itemCount, required this.onPickFiles, this.onPickFolder});

  final int itemCount;
  final VoidCallback? onPickFiles;
  final VoidCallback? onPickFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final bool hasItems = itemCount > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: palette?.field ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: palette?.border ?? theme.dividerColor,
          width: 1.5,
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: brand.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              hasItems ? Icons.collections_rounded : Icons.cloud_upload_outlined,
              color: brand,
              size: 21,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  itemCount > 0
                      ? '$itemCount file${itemCount == 1 ? '' : 's'} loaded'
                      : 'No files added',
                  key: const ValueKey<String>('rename-file-count'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: itemCount > 0
                        ? (palette?.text ?? theme.colorScheme.onSurface)
                        : (palette?.text ?? theme.colorScheme.onSurface),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Add images or a PDF to rename',
                  style: TextStyle(
                    fontSize: 11.5,
                    color:
                        palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const ValueKey<String>('rename-pick-files'),
            onPressed: onPickFiles,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text('Add Images'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey<String>('rename-pick-folder'),
            onPressed: onPickFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Add Folder'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ],
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
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 14),
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
        labelText: 'Prefix / Pattern',
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
      return _EmptyPreviewCard(palette: palette);
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
            Expanded(
              child: _PreviewList(
                controller: controller,
                palette: palette,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty-state shown in the preview column before any files are loaded, so the
/// right side of the wide layout is never a blank void (it mirrors the titled
/// card surface used everywhere else).
class _EmptyPreviewCard extends StatelessWidget {
  const _EmptyPreviewCard({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette?.border ?? theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: brand.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(Icons.visibility_outlined, color: brand, size: 26),
            ),
            const SizedBox(height: 14),
            Text(
              'Preview',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: palette?.text ?? theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Add images or a PDF to see the before / after names here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the before/after preview list (client-side computed pairs).
class _PreviewList extends StatelessWidget {
  const _PreviewList({required this.controller, required this.palette});

  final RenameController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final pairs = controller.previewPairs;
    final renameItems = controller.items;

    return GridView.builder(
      key: const ValueKey<String>('rename-preview-list'),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 450,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.35,
      ),
      itemCount: pairs.length,
      itemBuilder: (context, index) {
        if (index >= renameItems.length) return const SizedBox.shrink();
        return _PreviewCard(
          item: renameItems[index],
          renamedName: pairs[index].renamed,
          controller: controller,
          index: index,
          palette: palette,
        );
      },
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.item,
    required this.renamedName,
    required this.controller,
    required this.index,
    required this.palette,
  });

  final RenameItem item;
  final String renamedName;
  final RenameController controller;
  final int index;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = item.bytesForUpload();

    return Container(
      decoration: BoxDecoration(
        color: palette?.field ?? theme.colorScheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: palette?.border ?? theme.dividerColor,
          width: 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Image Preview Container - Expanded to fill available height in grid cell
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      showDialog<void>(
                        context: context,
                        barrierDismissible: true,
                        builder: (_) => _ImageViewerDialog(
                          controller: controller,
                          initialIndex: index,
                          palette: palette,
                        ),
                      );
                    },
                    child: Container(
                      color: Colors.black.withAlpha(20),
                      child: bytes.isNotEmpty
                          ? Image.memory(
                              item.getUint8List(),
                              fit: BoxFit.contain,
                            )
                          : const Center(
                              child: Icon(Icons.broken_image_outlined, size: 36),
                            ),
                    ),
                  ),
                ),
                // Delete button overlay
                Positioned(
                  top: 8,
                  right: 8,
                  child: _OverlayIconButton(
                    icon: Icons.delete_outline_rounded,
                    iconColor: Colors.redAccent,
                    tooltip: 'Delete Image',
                    onPressed: () => controller.removeItem(index),
                  ),
                ),
                // Reorder controls overlay
                Positioned(
                  top: 8,
                  left: 8,
                  child: Row(
                    children: [
                      if (index > 0) ...[
                        _OverlayIconButton(
                          icon: Icons.arrow_back_rounded,
                          tooltip: 'Move Left',
                          onPressed: () => controller.reorderItem(index, index - 1),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (index < controller.itemCount - 1)
                        _OverlayIconButton(
                          icon: Icons.arrow_forward_rounded,
                          tooltip: 'Move Right',
                          onPressed: () => controller.reorderItem(index, index + 1),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Compare Names Row (fixed height bottom container)
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: palette?.border ?? theme.dividerColor,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Original',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: palette?.text ?? theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 14,
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Renamed',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        renamedName,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: palette?.text ?? theme.colorScheme.onSurface,
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
    );
  }
}

/// The "Rename & Download" button.
class _RenameButton extends StatelessWidget {
  const _RenameButton({
    required this.busy,
    required this.enabled,
    required this.onRename,
    required this.itemCount,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback? onRename;
  final int itemCount;

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
      label: Text(
        itemCount > 0
            ? 'Rename & Download ZIP ($itemCount file${itemCount == 1 ? '' : 's'})'
            : 'Rename & Download ZIP',
      ),
    );
  }
}

class _ImageGalleryRow extends StatelessWidget {
  const _ImageGalleryRow({required this.controller, required this.palette});

  final RenameController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = palette?.border ?? theme.dividerColor;

    return Container(
      height: 130,
      decoration: BoxDecoration(
        color: palette?.panel ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Loaded Images (${controller.itemCount})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette?.text ?? theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  'Click to view each image',
                  style: TextStyle(
                    fontSize: 11,
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              itemCount: controller.itemCount,
              itemBuilder: (context, index) {
                final item = controller.items[index];
                return _GalleryThumbnail(
                  item: item,
                  index: index,
                  controller: controller,
                  palette: palette,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryThumbnail extends StatelessWidget {
  const _GalleryThumbnail({
    required this.item,
    required this.index,
    required this.controller,
    required this.palette,
  });

  final RenameItem item;
  final int index;
  final RenameController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = item.bytesForUpload();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) => _ImageViewerDialog(
              controller: controller,
              initialIndex: index,
              palette: palette,
            ),
          );
        },
        child: Container(
          width: 80,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: palette?.border ?? theme.dividerColor,
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              bytes.isNotEmpty
                  ? Image.memory(
                      item.getUint8List(),
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: Colors.black.withAlpha(20),
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined, size: 20),
                      ),
                    ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black.withAlpha(160),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageViewerDialog extends StatefulWidget {
  const _ImageViewerDialog({
    required this.controller,
    required this.initialIndex,
    required this.palette,
  });

  final RenameController controller;
  final int initialIndex;
  final QpicPalette? palette;

  @override
  State<_ImageViewerDialog> createState() => _ImageViewerDialogState();
}

class _ImageViewerDialogState extends State<_ImageViewerDialog> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  void _next() {
    if (_currentIndex < widget.controller.items.length - 1) {
      setState(() {
        _currentIndex++;
      });
    }
  }

  void _prev() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
    }
  }

  void _deleteCurrent() {
    final itemsCount = widget.controller.items.length;
    if (itemsCount == 0) {
      Navigator.of(context).pop();
      return;
    }

    widget.controller.removeItem(_currentIndex);

    final newCount = widget.controller.items.length;
    if (newCount == 0) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        if (_currentIndex >= newCount) {
          _currentIndex = newCount - 1;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.controller.items.isEmpty || _currentIndex >= widget.controller.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }

    final item = widget.controller.items[_currentIndex];
    final bytes = item.bytesForUpload();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                behavior: HitTestBehavior.translucent,
                child: const SizedBox.expand(),
              ),
            ),
            Center(
              child: GestureDetector(
                onTap: () {}, // Prevent closing when tapping card itself
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
                  decoration: BoxDecoration(
                    color: widget.palette?.panel ?? theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: widget.palette?.border ?? theme.dividerColor,
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(80),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: widget.palette?.text ?? theme.colorScheme.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (item.width != null && item.height != null) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      '${item.width} × ${item.height} px • ${_humanSize(item.sizeBytes)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: widget.palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                color: Colors.redAccent,
                              ),
                              tooltip: 'Delete Image',
                              onPressed: _deleteCurrent,
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                color: widget.palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // Main content
                      Expanded(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(24.0),
                              child: bytes.isNotEmpty
                                  ? InteractiveViewer(
                                      maxScale: 4.0,
                                      child: Image.memory(
                                        item.getUint8List(),
                                        fit: BoxFit.contain,
                                      ),
                                    )
                                  : const Center(
                                      child: Text('Could not load image'),
                                    ),
                            ),
                            // Navigation
                            if (_currentIndex > 0)
                              Positioned(
                                left: 16,
                                child: CircleAvatar(
                                  backgroundColor: Colors.black.withAlpha(120),
                                  child: IconButton(
                                    icon: const Icon(Icons.chevron_left, color: Colors.white),
                                    onPressed: _prev,
                                  ),
                                ),
                              ),
                            if (_currentIndex < widget.controller.items.length - 1)
                              Positioned(
                                right: 16,
                                child: CircleAvatar(
                                  backgroundColor: Colors.black.withAlpha(120),
                                  child: IconButton(
                                    icon: const Icon(Icons.chevron_right, color: Colors.white),
                                    onPressed: _next,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // Footer
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        child: Center(
                          child: Text(
                            'Image ${_currentIndex + 1} of ${widget.controller.items.length}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: widget.palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({
    required this.icon,
    required this.onPressed,
    this.iconColor,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? iconColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? Colors.black.withAlpha(160) : Colors.white.withAlpha(200);
    final fg = iconColor ?? (isDark ? Colors.white : Colors.black87);

    Widget button = Material(
      color: bg,
      type: MaterialType.circle,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 18,
            color: onPressed != null ? fg : fg.withAlpha(80),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      button = Tooltip(
        message: tooltip!,
        child: button,
      );
    }

    return button;
  }
}
