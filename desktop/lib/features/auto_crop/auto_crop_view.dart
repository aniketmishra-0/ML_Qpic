// Auto Crop form view (Requirements 5.1, 5.2, 5.3).
//
// [AutoCropView] renders every Auto Crop control backed by an
// [AutoCropController]: the Questions/Solutions toggles with their page-range
// fields, the Smart / Online / Answer-sheet toggles, the question-numbering
// selector, and the output configuration (prefixes, start number, image
// format, JPG quality, DPI, padding). Each control is constrained to the
// engine's accepted bounds (Requirement 5.3) using input formatters, sliders,
// and dropdowns so an out-of-range value can never be entered in the UI.
//
// This view holds NO engine logic and issues NO requests. The submit guards
// and the `POST /api/crop` / `POST /api/analyze` calls are tasks 9.2 / 12.5;
// the view exposes a placeholder Crop button via [onSubmit] that those tasks
// wire up. Every interactive widget carries a stable `ValueKey` so the
// form-guard widget tests (task 9.4) can drive it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme_controller.dart';
import '../../models/crop.dart';
import 'auto_crop_controller.dart';

/// Stateless form surface for the Auto Crop tool.
///
/// Listens to [controller] via an [AnimatedBuilder] so every control reflects
/// the controller's clamped/truncated state, the submit guard prompt / engine
/// error ([AutoCropController.errorText]), the busy flag, and the crop result's
/// download actions. [errorText] / [fileName] / [busy] may be supplied by the
/// host to override the controller's own values (e.g. while a file is being
/// loaded); when null they fall back to the controller.
class AutoCropView extends StatelessWidget {
  const AutoCropView({
    super.key,
    required this.controller,
    this.onSubmit,
    this.onPickFile,
    this.onClear,
    this.onView,
    this.fileName,
    this.errorText,
    this.busy = false,
  });

  /// Backing form state. The view never mutates anything other than this.
  final AutoCropController controller;

  /// Invoked when the user taps the Crop / Analyze button. The host typically
  /// wires this to [AutoCropController.submit] (which runs the guards and, when
  /// Smart mode is off, the direct crop) and to the Smart analyze entry (task
  /// 12.5). When null the button is disabled.
  final VoidCallback? onSubmit;

  /// Invoked when the user taps the "Choose PDF" affordance. Wired by the
  /// file-picker integration; when null the affordance is disabled.
  final VoidCallback? onPickFile;

  /// Invoked when the user taps the "Clear" affordance to reset the form back
  /// to its defaults. Typically wired to [AutoCropController.reset]. When null
  /// the affordance is hidden.
  final VoidCallback? onClear;

  /// Invoked when the user taps the "View" affordance to preview the selected
  /// PDF in an in-app popup. The host renders the page previews and opens the
  /// dialog. When null (no file loaded or engine not ready) the affordance is
  /// hidden / disabled.
  final VoidCallback? onView;

  /// Name of the currently selected PDF, shown next to the picker. When null
  /// the controller's own [AutoCropController.fileName] is shown instead.
  final String? fileName;

  /// Optional message shown above the form. When null the controller's own
  /// [AutoCropController.errorText] (guard prompt or engine error) is shown.
  final String? errorText;

  /// When true, the Crop button shows a busy state and is disabled. OR-ed with
  /// the controller's own [AutoCropController.busy].
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

    final String? shownError = errorText ?? controller.errorText;
    final String? shownFileName = fileName ?? controller.fileName;
    final bool isBusy = busy || controller.busy;

    // Full-bleed layout: the form spans the whole tool area (no narrow centered
    // column with empty side margins) and lays its sections across two columns
    // so everything fits without an outer scroll. On a narrow window the two
    // columns collapse into one, which can then scroll as a fallback.
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
                busy: isBusy,
              ),
              const SizedBox(height: 16),
              _FilePickerRow(
                fileName: shownFileName,
                onPickFile: onPickFile,
                onView: onView,
                previewLoading: controller.previewLoading,
              ),
              if (shownError != null) ...<Widget>[
                const SizedBox(height: 14),
                _ErrorBanner(message: shownError, palette: palette),
              ],
              const SizedBox(height: 18),
              Expanded(
                child: wide
                    ? _buildWideBody(context, palette, isBusy)
                    : _buildNarrowBody(context, palette, isBusy),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Two-column body for wide windows: Pages + Detection on the left, Output +
  /// Render + actions on the right. Each column scrolls independently only if
  /// its own content can't fit, so the page itself never needs to scroll.
  Widget _buildWideBody(
    BuildContext context,
    QpicPalette? palette,
    bool isBusy,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _SectionCard(
                  title: 'Pages',
                  palette: palette,
                  children: <Widget>[
                    _QuestionsSection(controller: controller),
                    const SizedBox(height: 16),
                    _SolutionsSection(controller: controller),
                  ],
                ),
                const SizedBox(height: 16),
                _SectionCard(
                  title: 'Detection',
                  palette: palette,
                  children: <Widget>[
                    _ModeToggles(controller: controller),
                    const SizedBox(height: 16),
                    _NumberingSelector(controller: controller),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
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
                    _RenderConfig(controller: controller),
                  ],
                ),
                const SizedBox(height: 20),
                _SubmitButton(
                  smartMode: controller.smartMode,
                  busy: isBusy,
                  onSubmit: onSubmit,
                ),
                if (controller.result != null) ...<Widget>[
                  const SizedBox(height: 20),
                  _DownloadCard(controller: controller, palette: palette),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Single-column body for narrow windows. Scrolls as a fallback so the form
  /// stays usable when there isn't room for two side-by-side columns.
  Widget _buildNarrowBody(
    BuildContext context,
    QpicPalette? palette,
    bool isBusy,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionCard(
            title: 'Pages',
            palette: palette,
            children: <Widget>[
              _QuestionsSection(controller: controller),
              const SizedBox(height: 16),
              _SolutionsSection(controller: controller),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Detection',
            palette: palette,
            children: <Widget>[
              _ModeToggles(controller: controller),
              const SizedBox(height: 16),
              _NumberingSelector(controller: controller),
            ],
          ),
          const SizedBox(height: 16),
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
              _RenderConfig(controller: controller),
            ],
          ),
          const SizedBox(height: 20),
          _SubmitButton(
            smartMode: controller.smartMode,
            busy: isBusy,
            onSubmit: onSubmit,
          ),
          if (controller.result != null) ...<Widget>[
            const SizedBox(height: 20),
            _DownloadCard(controller: controller, palette: palette),
          ],
        ],
      ),
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
                'Auto Crop',
                key: const ValueKey<String>('auto-crop-title'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Choose a PDF, set the page ranges and output options, then crop.',
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
            key: const ValueKey<String>('auto-crop-clear'),
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

class _FilePickerRow extends StatelessWidget {
  const _FilePickerRow({
    required this.fileName,
    required this.onPickFile,
    this.onView,
    this.previewLoading = false,
  });

  final String? fileName;
  final VoidCallback? onPickFile;
  final VoidCallback? onView;
  final bool previewLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final bool hasFile = fileName != null;

    final dropZone = _HoverDropZone(
      key: const ValueKey<String>('auto-crop-pick-file'),
      enabled: onPickFile != null,
      onTap: onPickFile,
      builder: (context, hovered) {
        final bool active = hovered && onPickFile != null;
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
                child: Icon(
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
                      key: const ValueKey<String>('auto-crop-file-name'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasFile ? 'Tap to choose a different PDF' : 'or click to browse',
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

    // The View affordance only appears once a PDF is loaded. It sits outside
    // the drop zone's tap target so previewing never triggers a file re-pick.
    if (!hasFile) return dropZone;
    return Row(
      children: <Widget>[
        Expanded(child: dropZone),
        const SizedBox(width: 12),
        _ViewButton(
          onView: onView,
          loading: previewLoading,
          palette: palette,
        ),
      ],
    );
  }
}

/// The "View" affordance shown beside a loaded PDF: opens the in-app preview
/// popup. Shows a spinner while the engine renders the page previews.
class _ViewButton extends StatelessWidget {
  const _ViewButton({
    required this.onView,
    required this.loading,
    required this.palette,
  });

  final VoidCallback? onView;
  final bool loading;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    return OutlinedButton.icon(
      key: const ValueKey<String>('auto-crop-view'),
      onPressed: loading ? null : onView,
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.visibility_outlined, size: 18),
      label: const Text('View'),
      style: OutlinedButton.styleFrom(
        foregroundColor: brand,
        side: BorderSide(color: brand.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      ),
    );
  }
}

/// A hoverable, clickable zone that reports its hover state to [builder].
/// Used to turn the file picker rows into prominent drop-zone style targets
/// without changing the host's callback contract.
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
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
      key: const ValueKey<String>('auto-crop-error'),
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
    // Use a Material (not a colored Container) as the card surface so the
    // SwitchListTiles inside paint their background/ink on it directly — a
    // colored DecoratedBox between a ListTile and its Material is flagged by
    // Flutter. The border is carried by the Material's shape.
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

class _QuestionsSection extends StatelessWidget {
  const _QuestionsSection({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          key: const ValueKey<String>('auto-crop-has-questions'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Questions'),
          subtitle: const Text('Crop the question pages of this PDF.'),
          value: controller.hasQuestions,
          onChanged: (value) => controller.hasQuestions = value,
        ),
        if (controller.hasQuestions)
          _PageRangeField(
            fieldKey: const ValueKey<String>('auto-crop-question-pages'),
            label: 'Question pages',
            hint: "e.g. '1-5' or '1 to 5, 8'",
            value: controller.questionPages,
            onChanged: (value) => controller.questionPages = value,
          ),
      ],
    );
  }
}

class _SolutionsSection extends StatelessWidget {
  const _SolutionsSection({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          key: const ValueKey<String>('auto-crop-has-answers'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Solutions'),
          subtitle: const Text('Crop the answer / solution pages of this PDF.'),
          value: controller.hasAnswers,
          onChanged: (value) => controller.hasAnswers = value,
        ),
        if (controller.hasAnswers)
          _PageRangeField(
            fieldKey: const ValueKey<String>('auto-crop-answer-pages'),
            label: 'Answer / solution pages',
            hint: "e.g. '7-10'",
            value: controller.answerPages,
            onChanged: (value) => controller.answerPages = value,
          ),
      ],
    );
  }
}

/// A free-text page-range field. Page ranges are validated by the engine, so
/// the field accepts digits, separators (`-`, `,`), the word `to`, and spaces
/// while filtering out anything else.
class _PageRangeField extends StatefulWidget {
  const _PageRangeField({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final String hint;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_PageRangeField> createState() => _PageRangeFieldState();
}

class _PageRangeFieldState extends State<_PageRangeField> {
  late final TextEditingController _textController =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _PageRangeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the field in sync if the controller value changed elsewhere
    // (e.g. a reset), without disturbing the cursor during normal typing.
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
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
      child: TextField(
        key: widget.fieldKey,
        controller: _textController,
        keyboardType: TextInputType.text,
        inputFormatters: <TextInputFormatter>[
          // Accept digits, range/list separators, the word "to", and spaces.
          FilteringTextInputFormatter.allow(RegExp(r'[0-9,\-to ]')),
        ],
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

class _ModeToggles extends StatelessWidget {
  const _ModeToggles({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SwitchListTile(
          key: const ValueKey<String>('auto-crop-smart-mode'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Smart mode'),
          subtitle:
              const Text('Analyze and review detections before downloading.'),
          value: true,
          onChanged: null,
        ),
        SwitchListTile(
          key: const ValueKey<String>('auto-crop-online-mode'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Online mode (Coming Soon)'),
          subtitle: const Text('Allow the AI vision tier when configured.'),
          value: false,
          onChanged: null,
        ),
        SwitchListTile(
          key: const ValueKey<String>('auto-crop-answer-sheet'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Answer sheet'),
          subtitle:
              const Text('Bundle an answer sheet when the paper has a key.'),
          value: controller.answerSheet,
          onChanged: (value) => controller.answerSheet = value,
        ),
      ],
    );
  }
}

class _NumberingSelector extends StatelessWidget {
  const _NumberingSelector({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Question numbering', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        DropdownButtonFormField<NumberingMode>(
          key: const ValueKey<String>('auto-crop-numbering'),
          initialValue: controller.numbering,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<NumberingMode>>[
            for (final mode in NumberingMode.values)
              DropdownMenuItem<NumberingMode>(
                value: mode,
                child: Text(mode.label),
              ),
          ],
          onChanged: (mode) {
            if (mode != null) controller.numbering = mode;
          },
        ),
      ],
    );
  }
}

class _OutputConfig extends StatelessWidget {
  const _OutputConfig({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _PrefixField(
                fieldKey: const ValueKey<String>('auto-crop-question-prefix'),
                label: 'Question prefix',
                value: controller.questionPrefix,
                onChanged: (value) => controller.questionPrefix = value,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PrefixField(
                fieldKey: const ValueKey<String>('auto-crop-solution-prefix'),
                label: 'Solution prefix',
                value: controller.solutionPrefix,
                onChanged: (value) => controller.solutionPrefix = value,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _BoundedIntField(
          fieldKey: const ValueKey<String>('auto-crop-start-number'),
          label: 'Start number',
          value: controller.startNumber,
          min: AutoCropBounds.startNumberMin,
          max: AutoCropBounds.startNumberMax,
          onChanged: (value) => controller.startNumber = value,
        ),
        const SizedBox(height: 16),
        _ImageFormatSelector(controller: controller),
        if (controller.imageFormat == CropImageFormat.jpg) ...<Widget>[
          const SizedBox(height: 16),
          _BoundedSlider(
            sliderKey: const ValueKey<String>('auto-crop-jpg-quality'),
            label: 'JPG quality',
            value: controller.jpgQuality,
            min: AutoCropBounds.jpgQualityMin,
            max: AutoCropBounds.jpgQualityMax,
            onChanged: (value) => controller.jpgQuality = value,
          ),
        ],
      ],
    );
  }
}

class _ImageFormatSelector extends StatelessWidget {
  const _ImageFormatSelector({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Image format', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        SegmentedButton<CropImageFormat>(
          key: const ValueKey<String>('auto-crop-image-format'),
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

class _RenderConfig extends StatelessWidget {
  const _RenderConfig({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _BoundedSlider(
          sliderKey: const ValueKey<String>('auto-crop-dpi'),
          label: 'DPI',
          value: controller.dpi,
          min: AutoCropBounds.dpiMin,
          max: AutoCropBounds.dpiMax,
          onChanged: (value) => controller.dpi = value,
        ),
        const SizedBox(height: 16),
        _BoundedSlider(
          sliderKey: const ValueKey<String>('auto-crop-padding'),
          label: 'Padding',
          value: controller.padding,
          min: AutoCropBounds.paddingMin,
          max: AutoCropBounds.paddingMax,
          onChanged: (value) => controller.padding = value,
        ),
      ],
    );
  }
}

/// A prefix text field constrained to [AutoCropBounds.prefixMaxLength]
/// characters via a [LengthLimitingTextInputFormatter] (Requirement 5.3).
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

/// An integer text field constrained to digits and clamped to `[min, max]` on
/// every edit (Requirement 5.3). The controller clamps as well, so a value
/// outside the range can never reach the engine.
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
    // Only force-sync when the controller's clamped value diverges from the
    // raw text (e.g. the user typed an over-max value that was clamped down).
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
    if (raw.isEmpty) return; // allow transient empty field while editing
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

/// A labelled slider bounded to `[min, max]` that always emits an in-range
/// integer (Requirement 5.3). Used for DPI, padding, and JPG quality.
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
    // Guard against an out-of-range incoming value so the Slider never asserts.
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
              key: ValueKey<String>('${(sliderKey as ValueKey<String>).value}-value'),
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

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.smartMode,
    required this.busy,
    required this.onSubmit,
  });

  final bool smartMode;
  final bool busy;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    // Smart mode opens the review canvas; non-Smart crops straight to a ZIP.
    final label = smartMode ? 'Analyze & Review' : 'Crop';
    return FilledButton.icon(
      key: const ValueKey<String>('auto-crop-submit'),
      onPressed: busy ? null : onSubmit,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(smartMode ? Icons.travel_explore : Icons.crop),
      label: Text(label),
    );
  }
}

/// The result block shown after a successful direct crop. Presents a download
/// action only for each archive the [CropResponse] reports as available: the
/// Combined archive always, and the Questions-only / Solutions-only archives
/// when the engine returned their URLs (Requirement 5.9, 11.1–11.3).
class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.controller, required this.palette});

  final AutoCropController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = controller.result!;
    final success = palette?.success ?? theme.colorScheme.primary;

    return Material(
      key: const ValueKey<String>('auto-crop-result'),
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
              'Crop complete',
              key: const ValueKey<String>('auto-crop-result-title'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: success,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _summary(result),
              key: const ValueKey<String>('auto-crop-result-summary'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // Combined archive is always available (Requirement 11.1).
            FilledButton.icon(
              key: const ValueKey<String>('auto-crop-download-combined'),
              onPressed: controller.canDownload(CropArchive.combined)
                  ? () => controller.download(CropArchive.combined)
                  : null,
              icon: const Icon(Icons.download),
              label: const Text('Download combined ZIP'),
            ),
            // Questions-only, only when the engine reported its URL (11.2).
            if (controller.canDownload(CropArchive.questions)) ...<Widget>[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey<String>('auto-crop-download-questions'),
                onPressed: () => controller.download(CropArchive.questions),
                icon: const Icon(Icons.help_outline),
                label: const Text('Download questions only'),
              ),
            ],
            // Solutions-only, only when the engine reported its URL (11.3).
            if (controller.canDownload(CropArchive.solutions)) ...<Widget>[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey<String>('auto-crop-download-solutions'),
                onPressed: () => controller.download(CropArchive.solutions),
                icon: const Icon(Icons.lightbulb_outline),
                label: const Text('Download solutions only'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A short, count-based summary mirroring what the engine reported.
  static String _summary(CropResponse result) {
    final parts = <String>[];
    if (result.questionsCount > 0) {
      parts.add('${result.questionsCount} question'
          '${result.questionsCount == 1 ? '' : 's'}');
    }
    if (result.solutionsCount > 0) {
      parts.add('${result.solutionsCount} solution'
          '${result.solutionsCount == 1 ? '' : 's'}');
    }
    final counts = parts.isEmpty ? 'No items' : parts.join(' · ');
    final sheet = result.answerSheetIncluded ? ' · answer sheet included' : '';
    return '$counts$sheet';
  }
}
