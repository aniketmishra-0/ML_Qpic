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
                    const SizedBox(height: 16),
                    _SkipPagesSection(controller: controller),
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
                    const SizedBox(height: 16),
                    _LayoutColumnsSelector(controller: controller),
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
              const SizedBox(height: 16),
              _SkipPagesSection(controller: controller),
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
              const SizedBox(height: 16),
              _LayoutColumnsSelector(controller: controller),
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
    final successColor = palette?.success ?? theme.colorScheme.primary;
    final bool hasFile = fileName != null;

    final dropZone = _HoverDropZone(
      key: const ValueKey<String>('auto-crop-pick-file'),
      enabled: onPickFile != null,
      onTap: onPickFile,
      builder: (context, hovered) {
        final bool active = hovered && onPickFile != null;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: active
                ? brand.withValues(alpha: 0.08)
                : (hasFile 
                    ? (palette?.panelAlt ?? theme.colorScheme.surface)
                    : (palette?.field ?? theme.colorScheme.surfaceContainerHighest)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active 
                  ? brand 
                  : (hasFile 
                      ? successColor.withValues(alpha: 0.5) 
                      : (palette?.border ?? theme.dividerColor)),
              width: 1.5,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: brand.withValues(alpha: 0.15),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    )
                  ]
                : [],
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: hasFile 
                      ? successColor.withValues(alpha: 0.12)
                      : brand.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  hasFile
                      ? Icons.picture_as_pdf_rounded
                      : Icons.cloud_upload_outlined,
                  color: hasFile ? successColor : brand,
                  size: 22,
                ),
              ),
              const SizedBox(width: 16),
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
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
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
              if (hasFile) ...[
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: successColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: successColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'LOADED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: successColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
        const SizedBox(width: 14),
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
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(brand),
              ),
            )
          : const Icon(Icons.remove_red_eye_rounded, size: 18),
      label: const Text('View'),
      style: OutlinedButton.styleFrom(
        foregroundColor: brand,
        side: BorderSide(color: brand.withValues(alpha: 0.4), width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
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
    final accentColor = _getAccentColor(palette);
    final sectionIcon = _getIcon();

    // Use a Material (not a colored Container) as the card surface so the
    // SwitchListTiles inside paint their background/ink on it directly.
    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      elevation: 2,
      shadowColor: (palette?.border ?? theme.dividerColor).withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette?.borderSoft ?? theme.dividerColor, width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    sectionIcon,
                    size: 18,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: palette?.text ?? theme.colorScheme.onSurface,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Color _getAccentColor(QpicPalette? palette) {
    switch (title) {
      case 'Pages':
        return palette?.brand ?? const Color(0xFF7C6CFF);
      case 'Detection':
        return palette?.brandMagenta ?? const Color(0xFFB14EFF);
      case 'Output':
        return palette?.brandBlue ?? const Color(0xFF4B8DFF);
      case 'Render':
        return palette?.warn ?? const Color(0xFFFBBF24);
      default:
        return palette?.brand ?? const Color(0xFF7C6CFF);
    }
  }

  IconData _getIcon() {
    switch (title) {
      case 'Pages':
        return Icons.auto_stories_rounded;
      case 'Detection':
        return Icons.psychology_rounded;
      case 'Output':
        return Icons.snippet_folder_rounded;
      case 'Render':
        return Icons.display_settings_rounded;
      default:
        return Icons.settings_rounded;
    }
  }
}

class _QuestionsSection extends StatelessWidget {
  const _QuestionsSection({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Material(
      color: controller.hasQuestions 
          ? brand.withValues(alpha: 0.03) 
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: controller.hasQuestions 
              ? brand.withValues(alpha: 0.3) 
              : (palette?.borderSoft ?? theme.dividerColor),
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            key: const ValueKey<String>('auto-crop-has-questions'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            title: Row(
              children: [
                Icon(
                  Icons.help_outline_rounded,
                  size: 20,
                  color: controller.hasQuestions ? brand : palette?.muted,
                ),
                const SizedBox(width: 10),
                Text(
                  'Questions',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: controller.hasQuestions ? palette?.text : palette?.muted,
                  ),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Text(
                'Crop the question pages of this PDF.',
                style: TextStyle(fontSize: 12.5, color: palette?.mutedAlt),
              ),
            ),
            value: controller.hasQuestions,
            onChanged: (value) => controller.hasQuestions = value,
          ),
          if (controller.hasQuestions) ...[
            const Divider(height: 1, thickness: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: _PageRangeField(
                fieldKey: const ValueKey<String>('auto-crop-question-pages'),
                label: 'Question pages range',
                hint: "e.g. '1-5' or '1 to 5, 8'",
                value: controller.questionPages,
                onChanged: (value) => controller.questionPages = value,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SolutionsSection extends StatelessWidget {
  const _SolutionsSection({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Material(
      color: controller.hasAnswers 
          ? brand.withValues(alpha: 0.03) 
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: controller.hasAnswers 
              ? brand.withValues(alpha: 0.3) 
              : (palette?.borderSoft ?? theme.dividerColor),
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            key: const ValueKey<String>('auto-crop-has-answers'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            title: Row(
              children: [
                Icon(
                  Icons.lightbulb_outline_rounded,
                  size: 20,
                  color: controller.hasAnswers ? brand : palette?.muted,
                ),
                const SizedBox(width: 10),
                Text(
                  'Solutions',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: controller.hasAnswers ? palette?.text : palette?.muted,
                  ),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Text(
                'Crop the answer / solution pages of this PDF.',
                style: TextStyle(fontSize: 12.5, color: palette?.mutedAlt),
              ),
            ),
            value: controller.hasAnswers,
            onChanged: (value) => controller.hasAnswers = value,
          ),
          if (controller.hasAnswers) ...[
            const Divider(height: 1, thickness: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: _PageRangeField(
                fieldKey: const ValueKey<String>('auto-crop-answer-pages'),
                label: 'Answer / solution pages range',
                hint: "e.g. '7-10'",
                value: controller.answerPages,
                onChanged: (value) => controller.answerPages = value,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SkipPagesSection extends StatelessWidget {
  const _SkipPagesSection({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final danger = palette?.danger ?? theme.colorScheme.error;

    return Container(
      decoration: BoxDecoration(
        color: controller.skipPages.isNotEmpty 
            ? danger.withValues(alpha: 0.02) 
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: controller.skipPages.isNotEmpty 
              ? danger.withValues(alpha: 0.25) 
              : (palette?.borderSoft ?? theme.dividerColor),
          width: 1.2,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: [
              Icon(
                Icons.block_rounded,
                size: 18,
                color: controller.skipPages.isNotEmpty ? danger : palette?.muted,
              ),
              const SizedBox(width: 10),
              Text(
                'Skip Pages (Optional)',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: controller.skipPages.isNotEmpty ? palette?.text : palette?.muted,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              'Exclude specific page numbers from the crop output.',
              style: TextStyle(fontSize: 12, color: palette?.mutedAlt),
            ),
          ),
          const SizedBox(height: 12),
          _PageRangeField(
            fieldKey: const ValueKey<String>('auto-crop-skip-pages'),
            label: 'Pages to exclude',
            hint: "e.g. '3, 5' or '12'",
            value: controller.skipPages,
            onChanged: (value) => controller.skipPages = value,
          ),
        ],
      ),
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
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return TextField(
      key: widget.fieldKey,
      controller: _textController,
      keyboardType: TextInputType.text,
      inputFormatters: <TextInputFormatter>[
        // Accept digits, range/list separators, the word "to", and spaces.
        FilteringTextInputFormatter.allow(RegExp(r'[0-9,\-to ]')),
      ],
      style: TextStyle(
        fontSize: 14,
        color: palette?.text ?? theme.colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
        prefixIcon: Icon(
          Icons.pin_outlined,
          size: 16,
          color: palette?.muted,
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

class _ModeToggles extends StatelessWidget {
  const _ModeToggles({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Column(
      children: <Widget>[
        _buildToggleItem(
          key: const ValueKey<String>('auto-crop-smart-mode'),
          icon: Icons.auto_awesome_rounded,
          title: 'Smart Mode',
          subtitle: 'Analyze and review detections before downloading.',
          value: controller.smartMode,
          onChanged: (value) => controller.smartMode = value,
          brandColor: brand,
          palette: palette,
          theme: theme,
        ),
        const SizedBox(height: 12),
        _buildToggleItem(
          key: const ValueKey<String>('auto-crop-online-mode'),
          icon: Icons.cloud_outlined,
          title: 'Online Mode (Coming Soon)',
          subtitle: 'Allow the AI vision tier when configured.',
          value: false,
          onChanged: null,
          brandColor: brand,
          palette: palette,
          theme: theme,
        ),
        const SizedBox(height: 12),
        _buildToggleItem(
          key: const ValueKey<String>('auto-crop-answer-sheet'),
          icon: Icons.checklist_rtl_rounded,
          title: 'Answer Sheet',
          subtitle: 'Bundle an answer sheet when the paper has a key.',
          value: controller.answerSheet,
          onChanged: (value) => controller.answerSheet = value,
          brandColor: brand,
          palette: palette,
          theme: theme,
        ),
      ],
    );
  }

  Widget _buildToggleItem({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required Color brandColor,
    required QpicPalette? palette,
    required ThemeData theme,
  }) {
    final active = value && onChanged != null;
    return Material(
      color: active ? brandColor.withValues(alpha: 0.03) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: active 
              ? brandColor.withValues(alpha: 0.3) 
              : (palette?.borderSoft ?? theme.dividerColor),
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        key: key,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        title: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: active ? brandColor : palette?.muted,
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: active ? palette?.text : palette?.muted,
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: palette?.mutedAlt),
          ),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _NumberingSelector extends StatelessWidget {
  const _NumberingSelector({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            'Question numbering',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette?.text ?? theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<NumberingMode>(
          key: const ValueKey<String>('auto-crop-numbering'),
          initialValue: controller.numbering,
          style: TextStyle(
            fontSize: 14,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(
              Icons.format_list_numbered_rounded,
              size: 18,
              color: palette?.muted,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

class _LayoutColumnsSelector extends StatelessWidget {
  const _LayoutColumnsSelector({required this.controller});

  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            'Page layout columns',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette?.text ?? theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<LayoutColumnsMode>(
          key: const ValueKey<String>('auto-crop-layout-columns'),
          initialValue: controller.layoutColumns,
          style: TextStyle(
            fontSize: 14,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(
              Icons.view_column_rounded,
              size: 18,
              color: palette?.muted,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: <DropdownMenuItem<LayoutColumnsMode>>[
            for (final mode in LayoutColumnsMode.values)
              DropdownMenuItem<LayoutColumnsMode>(
                value: mode,
                child: Text(mode.label),
              ),
          ],
          onChanged: (mode) {
            if (mode != null) controller.layoutColumns = mode;
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
    final palette = theme.extension<QpicPalette>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            'Image format',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette?.text ?? theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<CropImageFormat>(
            key: const ValueKey<String>('auto-crop-image-format'),
            segments: <ButtonSegment<CropImageFormat>>[
              for (final format in CropImageFormat.values)
                ButtonSegment<CropImageFormat>(
                  value: format,
                  label: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(format.label),
                  ),
                ),
            ],
            selected: <CropImageFormat>{controller.imageFormat},
            onSelectionChanged: (selection) {
              controller.imageFormat = selection.first;
            },
          ),
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
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return TextField(
      key: widget.fieldKey,
      controller: _textController,
      inputFormatters: <TextInputFormatter>[
        LengthLimitingTextInputFormatter(AutoCropBounds.prefixMaxLength),
      ],
      style: TextStyle(
        fontSize: 14,
        color: palette?.text ?? theme.colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        prefixIcon: Icon(
          Icons.title_rounded,
          size: 16,
          color: palette?.muted,
        ),
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
    final palette = theme.extension<QpicPalette>();
    return TextField(
      key: widget.fieldKey,
      controller: _textController,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      style: TextStyle(
        fontSize: 14,
        color: palette?.text ?? theme.colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: 'Range ${widget.min}–${widget.max}',
        isDense: true,
        prefixIcon: Icon(
          Icons.pin_outlined,
          size: 16,
          color: palette?.muted,
        ),
        helperStyle: TextStyle(
          fontSize: 11,
          color: palette?.mutedAlt,
        ),
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
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final clamped = value < min ? min : (value > max ? max : value);

    final sliderValueKeyString = (sliderKey as ValueKey<String>).value;
    final icon = _getIcon();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: palette?.muted,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette?.text ?? theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$clamped',
                key: ValueKey<String>('$sliderValueKeyString-value'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: brand,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: theme.sliderTheme.copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            key: sliderKey,
            value: clamped.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min > 0 ? max - min : 1,
            label: '$clamped',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
      ],
    );
  }

  IconData _getIcon() {
    if (label.toLowerCase().contains('quality')) {
      return Icons.high_quality_rounded;
    } else if (label.toLowerCase().contains('dpi')) {
      return Icons.photo_size_select_large_rounded;
    } else {
      return Icons.settings_overscan_rounded;
    }
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
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    // Smart mode opens the review canvas; non-Smart crops straight to a ZIP.
    final label = smartMode ? 'Analyze & Review' : 'Crop';
    final disabled = onSubmit == null || busy;

    return Container(
      decoration: BoxDecoration(
        gradient: disabled
            ? null
            : LinearGradient(
                colors: [
                  palette?.brand ?? const Color(0xFF7C6CFF),
                  palette?.brandMagenta ?? const Color(0xFFB14EFF),
                ],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
        color: disabled ? (palette?.border ?? theme.dividerColor) : null,
        borderRadius: BorderRadius.circular(12),
        boxShadow: disabled
            ? null
            : [
                BoxShadow(
                  color: (palette?.brand ?? const Color(0xFF7C6CFF)).withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: FilledButton.icon(
        key: const ValueKey<String>('auto-crop-submit'),
        onPressed: busy ? null : onSubmit,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Icon(smartMode ? Icons.travel_explore_rounded : Icons.crop_rounded),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          disabledForegroundColor: palette?.mutedAlt,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
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
