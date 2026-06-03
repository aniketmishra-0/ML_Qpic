// Manual Crop view (Requirements 7.1, 7.2, 7.3, 7.6).
//
// [ManualCropView] renders the Manual Crop tool backed by a
// [ManualCropController]. It has two surfaces:
//
//   * the OPEN form — a "Choose PDF" affordance plus the tool's OWN output
//     configuration (question/solution prefix, start number, image format
//     PNG/JPG, JPG quality) and the render DPI. These fields are independent of
//     the Auto Crop tool's (Req 7.3); the controller owns the values.
//   * the REVIEW CANVAS — shown once `POST /api/prepare-manual` succeeds, with
//     an empty item list and every page preview loaded from its engine
//     `preview_url` (Req 7.1, 7.2). The user hand-draws every crop here.
//
// On a prepare-manual error the canvas does NOT open and the engine `detail` is
// shown above the open form (Req 7.6). This view holds NO engine logic and
// issues NO requests directly: the open call, page loading, and the finalize
// (Req 7.4, wired via the shared ReviewScreen's `onFinalize`) live on the
// controller / shared ReviewController.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme_controller.dart';
import '../auto_crop/auto_crop_controller.dart'
    show AutoCropBounds, CropImageFormat;
import '../review/review_canvas.dart';
import '../review/review_screen.dart';
import 'manual_crop_controller.dart';

/// Stateless surface for the Manual Crop tool.
///
/// Listens to [controller] via an [AnimatedBuilder] so the open form reflects
/// the controller's clamped output config and the prepare-manual error, and so
/// the Review Canvas appears the moment the controller reports [canvasOpen].
/// [previewUrlResolver] joins each page's engine `preview_url` onto the live
/// Base_URL (the host passes [ApiClient.resolveUri]); when null the URL is used
/// verbatim.
class ManualCropView extends StatelessWidget {
  const ManualCropView({
    super.key,
    required this.controller,
    this.onPickFile,
    this.onClear,
    this.previewUrlResolver,
  });

  /// Backing tool state. The view never mutates anything other than this.
  final ManualCropController controller;

  /// Invoked when the user taps "Choose PDF". The host wires this to
  /// [ManualCropController.pickPdf] (which opens the native picker, loads the
  /// file, and opens the canvas). When null the affordance is disabled.
  final VoidCallback? onPickFile;

  /// Invoked when the user taps "Clear" to reset the tool back to its defaults.
  /// Typically wired to [ManualCropController.reset]. When null the affordance
  /// is hidden.
  final VoidCallback? onClear;

  /// Joins an engine `preview_url` onto the live Base_URL for the canvas. When
  /// null the `preview_url` is used verbatim.
  final PreviewUrlResolver? previewUrlResolver;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.canvasOpen) {
          // Reuse the shared Review Canvas host (same surface as Smart Auto
          // Crop). The manual session starts with an empty item list; the user
          // hand-draws every crop. Finalize (Req 7.4) calls the controller's
          // own finalize with its independent output config; the shared host's
          // empty-list guard (Req 7.5) and item-retention-on-error (Req 7.7)
          // drive the prompt / retry. The Finalize control is disabled until
          // the engine is bound.
          return ReviewScreen(
            key: const ValueKey<String>('manual-crop-canvas'),
            controller: controller.review,
            previewUrlResolver: previewUrlResolver,
            questionPrefix: controller.questionPrefix,
            solutionPrefix: controller.solutionPrefix,
            onClose: controller.closeCanvas,
            onFinalize:
                controller.engineReady ? () => controller.finalize() : null,
          );
        }
        return _OpenForm(
          controller: controller,
          onPickFile: onPickFile,
          onClear: onClear,
        );
      },
    );
  }
}

/// The open form: file picker + the tool's independent output configuration.
class _OpenForm extends StatelessWidget {
  const _OpenForm({
    required this.controller,
    required this.onPickFile,
    required this.onClear,
  });

  final ManualCropController controller;
  final VoidCallback? onPickFile;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final String? error = controller.errorText;

    // Full-bleed layout: spans the whole tool area (no narrow centered column
    // with empty side margins) and lays the Output + Render cards side by side
    // on a wide window so the form fits without a page-level scroll. A narrow
    // window stacks them in a single scrolling column.
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
                busy: controller.busy,
              ),
              const SizedBox(height: 16),
              _FilePickerRow(
                fileName: controller.fileName,
                busy: controller.busy,
                onPickFile: onPickFile,
              ),
              if (error != null) ...<Widget>[
                const SizedBox(height: 14),
                _ErrorBanner(message: error, palette: palette),
              ],
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: _SectionCard(
                                title: 'Output',
                                palette: palette,
                                children: <Widget>[
                                  _OutputConfig(controller: controller),
                                ],
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: _SectionCard(
                                title: 'Render',
                                palette: palette,
                                children: <Widget>[
                                  _BoundedSlider(
                                    sliderKey: const ValueKey<String>(
                                        'manual-crop-dpi'),
                                    label: 'DPI',
                                    value: controller.dpi,
                                    min: AutoCropBounds.dpiMin,
                                    max: AutoCropBounds.dpiMax,
                                    onChanged: (v) => controller.dpi = v,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _SectionCard(
                              title: 'Output',
                              palette: palette,
                              children: <Widget>[
                                _OutputConfig(controller: controller),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _SectionCard(
                              title: 'Render',
                              palette: palette,
                              children: <Widget>[
                                _BoundedSlider(
                                  sliderKey: const ValueKey<String>(
                                      'manual-crop-dpi'),
                                  label: 'DPI',
                                  value: controller.dpi,
                                  min: AutoCropBounds.dpiMin,
                                  max: AutoCropBounds.dpiMax,
                                  onChanged: (v) => controller.dpi = v,
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

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
                'Manual Crop',
                key: const ValueKey<String>('manual-crop-title'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Open a PDF to draw every crop by hand — no auto-detection.',
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
            key: const ValueKey<String>('manual-crop-clear'),
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

/// File picker styled as a prominent drop zone, mirroring the Auto Crop view
/// so both crop tools present an identical file affordance. Tapping anywhere in
/// the zone triggers [onPickFile]; a busy spinner replaces the icon while the
/// prepare-manual call is in flight.
class _FilePickerRow extends StatelessWidget {
  const _FilePickerRow({
    required this.fileName,
    required this.busy,
    required this.onPickFile,
  });

  final String? fileName;
  final bool busy;
  final VoidCallback? onPickFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final bool hasFile = fileName != null;
    final bool enabled = onPickFile != null && !busy;

    return _HoverDropZone(
      key: const ValueKey<String>('manual-crop-pick-file'),
      enabled: enabled,
      onTap: onPickFile,
      builder: (context, hovered) {
        final bool active = hovered && enabled;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: active
                ? brand.withValues(alpha: 0.06)
                : (palette?.field ?? theme.colorScheme.surfaceContainerHighest),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? brand : (palette?.border ?? theme.dividerColor),
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
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: brand,
                        ),
                      )
                    : Icon(
                        hasFile
                            ? Icons.picture_as_pdf_rounded
                            : Icons.cloud_upload_outlined,
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
                      hasFile ? fileName! : 'Drop your PDF here',
                      key: const ValueKey<String>('manual-crop-file-name'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasFile
                          ? 'Tap to choose a different PDF'
                          : 'or click to browse',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: palette?.mutedAlt ??
                            theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A hoverable, clickable zone that reports its hover state to [builder].
/// Mirrors the Auto Crop view's drop zone so the two crop tools share an
/// identical file affordance.
class _HoverDropZone extends StatefulWidget {
  const _HoverDropZone({
    super.key,
    required this.builder,
    required this.onTap,
    required this.enabled,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  State<_HoverDropZone> createState() => _HoverDropZoneState();
}

class _HoverDropZoneState extends State<_HoverDropZone> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: widget.builder(context, _hovered),
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
      key: const ValueKey<String>('manual-crop-error'),
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

/// The Manual Crop tool's own output configuration (Req 7.3). Identical layout
/// to the Auto Crop output card, but bound to the independent
/// [ManualCropController] fields.
class _OutputConfig extends StatelessWidget {
  const _OutputConfig({required this.controller});

  final ManualCropController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _PrefixField(
                fieldKey: const ValueKey<String>('manual-crop-question-prefix'),
                label: 'Question prefix',
                value: controller.questionPrefix,
                onChanged: (v) => controller.questionPrefix = v,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PrefixField(
                fieldKey: const ValueKey<String>('manual-crop-solution-prefix'),
                label: 'Solution prefix',
                value: controller.solutionPrefix,
                onChanged: (v) => controller.solutionPrefix = v,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _BoundedIntField(
          fieldKey: const ValueKey<String>('manual-crop-start-number'),
          label: 'Start number',
          value: controller.startNumber,
          min: AutoCropBounds.startNumberMin,
          max: AutoCropBounds.startNumberMax,
          onChanged: (v) => controller.startNumber = v,
        ),
        const SizedBox(height: 16),
        _ImageFormatSelector(controller: controller),
        if (controller.imageFormat == CropImageFormat.jpg) ...<Widget>[
          const SizedBox(height: 16),
          _BoundedSlider(
            sliderKey: const ValueKey<String>('manual-crop-jpg-quality'),
            label: 'JPG quality',
            value: controller.jpgQuality,
            min: AutoCropBounds.jpgQualityMin,
            max: AutoCropBounds.jpgQualityMax,
            onChanged: (v) => controller.jpgQuality = v,
          ),
        ],
      ],
    );
  }
}

class _ImageFormatSelector extends StatelessWidget {
  const _ImageFormatSelector({required this.controller});

  final ManualCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Image format', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        SegmentedButton<CropImageFormat>(
          key: const ValueKey<String>('manual-crop-image-format'),
          segments: <ButtonSegment<CropImageFormat>>[
            for (final format in CropImageFormat.values)
              ButtonSegment<CropImageFormat>(
                value: format,
                label: Text(format.label),
              ),
          ],
          selected: <CropImageFormat>{controller.imageFormat},
          onSelectionChanged: (selection) {
            controller.imageFormat = selection.first;
          },
        ),
      ],
    );
  }
}

/// A prefix text field constrained to [AutoCropBounds.prefixMaxLength] chars.
class _PrefixField extends StatefulWidget {
  const _PrefixField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_PrefixField> createState() => _PrefixFieldState();
}

class _PrefixFieldState extends State<_PrefixField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _PrefixField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _textController.text) {
      _textController.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
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
      key: widget.fieldKey,
      controller: _textController,
      inputFormatters: <TextInputFormatter>[
        LengthLimitingTextInputFormatter(AutoCropBounds.prefixMaxLength),
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        border: const OutlineInputBorder(),
        counterText: '',
      ),
      onChanged: widget.onChanged,
    );
  }
}

/// An integer field constrained to digits and clamped to `[min, max]`.
class _BoundedIntField extends StatefulWidget {
  const _BoundedIntField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<_BoundedIntField> createState() => _BoundedIntFieldState();
}

class _BoundedIntFieldState extends State<_BoundedIntField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.value.toString());

  @override
  void didUpdateWidget(covariant _BoundedIntField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.value.toString();
    final parsed = int.tryParse(_textController.text);
    if (parsed != widget.value && text != _textController.text) {
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
    widget.onChanged(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      key: widget.fieldKey,
      controller: _textController,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: 'Range ${widget.min}–${widget.max}',
        isDense: true,
        border: const OutlineInputBorder(),
        helperStyle: theme.textTheme.bodySmall,
      ),
      onChanged: _handleChanged,
    );
  }
}

/// A labelled slider bounded to `[min, max]` emitting an in-range integer.
class _BoundedSlider extends StatelessWidget {
  const _BoundedSlider({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final Key sliderKey;
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clamped = value < min ? min : (value > max ? max : value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(label, style: theme.textTheme.bodyMedium),
            Text(
              '$clamped',
              key: ValueKey<String>(
                  '${(sliderKey as ValueKey<String>).value}-value'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          key: sliderKey,
          value: clamped.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$clamped',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}
