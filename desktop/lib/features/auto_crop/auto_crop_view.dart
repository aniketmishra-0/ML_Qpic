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
import '../../models/tools.dart';
import '../../widgets/drop_target.dart';
import '../../widgets/enhancement_preview_dialog.dart';
import '../../widgets/qpic_dropdown.dart';
import 'auto_crop_controller.dart';
import 'batch_queue_controller.dart';

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
    final listenables = <Listenable>[controller];
    if (controller.batchQueue != null) {
      listenables.add(controller.batchQueue!);
    }
    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
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
                controller: controller,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeInOutCubic,
                  switchOutCurve: Curves.easeInOutCubic,
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.0, 0.03),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: controller.batchMode
                      ? Column(
                          key: const ValueKey<String>('batch-mode-layout'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (shownError != null) ...<Widget>[
                              _ErrorBanner(
                                  message: shownError, palette: palette),
                              const SizedBox(height: 14),
                            ],
                            Expanded(
                              child: wide
                                  ? _buildWideBatchBody(
                                      context, palette, isBusy)
                                  : _buildNarrowBatchBody(
                                      context, palette, isBusy),
                            ),
                          ],
                        )
                      : Column(
                          key: const ValueKey<String>('single-mode-layout'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FilePickerRow(
                              controller: controller,
                              fileName: shownFileName,
                              onPickFile: onPickFile,
                              onView: onView,
                              previewLoading: controller.previewLoading,
                            ),
                            if (shownError != null) ...<Widget>[
                              const SizedBox(height: 14),
                              _ErrorBanner(
                                  message: shownError, palette: palette),
                            ],
                            const SizedBox(height: 18),
                            Expanded(
                              child: wide
                                  ? _buildWideBody(context, palette, isBusy)
                                  : _buildNarrowBody(context, palette, isBusy),
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
                    const SizedBox(height: 16),
                    _AccuracySettingsPanel(controller: controller),
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
              const SizedBox(height: 16),
              _AccuracySettingsPanel(controller: controller),
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

  Widget _buildWideBatchBody(
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
                    const SizedBox(height: 16),
                    _AccuracySettingsPanel(controller: controller),
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
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: _BatchQueuePanel(
            controller: controller,
            palette: palette,
            onPickFile: onPickFile,
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowBatchBody(
    BuildContext context,
    QpicPalette? palette,
    bool isBusy,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _BatchDropZone(
            onPickFiles: onPickFile,
            queue: controller.batchQueue,
            palette: palette,
          ),
          const SizedBox(height: 16),
          if (controller.batchQueue != null &&
              controller.batchQueue!.items.isNotEmpty) ...[
            _BatchQueueList(
              controller: controller,
              palette: palette,
            ),
            const SizedBox(height: 16),
          ],
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
              const SizedBox(height: 16),
              _AccuracySettingsPanel(controller: controller),
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
    required this.controller,
  });

  final QpicPalette? palette;
  final VoidCallback? onClear;
  final bool busy;
  final AutoCropController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
        // Batch Mode toggle
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Batch Mode',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: controller.batchMode
                    ? brand
                    : (palette?.muted ?? theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              key: const ValueKey<String>('auto-crop-batch-mode-toggle'),
              value: controller.batchMode,
              onChanged: busy
                  ? null
                  : (val) {
                      controller.batchMode = val;
                    },
              activeColor: brand,
            ),
          ],
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
    required this.controller,
    required this.fileName,
    required this.onPickFile,
    this.onView,
    this.previewLoading = false,
  });

  final AutoCropController controller;
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

    final dropZone = DropFileTarget.pdfOnly(
      enabled: onPickFile != null && !controller.busy,
      onAccepted: (files) async {
        if (files.isEmpty) return;
        final file = files.first;
        final bytes = await file.readAsBytes();
        controller.setFile(bytes: bytes, filename: file.name);
      },
      onRejected: (msg) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      },
      child: _HoverDropZone(
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
                      : (palette?.field ??
                          theme.colorScheme.surfaceContainerHighest)),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active
                    ? brand
                    : (hasFile
                        ? successColor.withValues(alpha: 0.3)
                        : (palette?.borderSoft ?? theme.dividerColor).withValues(alpha: 0.5)),
                width: 1.0,
              ),
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
                if (hasFile) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
      ),
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

    // Borderless, clean card — no visible box, just spacing and subtle divider.
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
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
          : (palette?.panel ?? theme.colorScheme.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            key: const ValueKey<String>('auto-crop-has-questions'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                    color: controller.hasQuestions
                        ? palette?.text
                        : palette?.muted,
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
          : (palette?.panel ?? theme.colorScheme.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            key: const ValueKey<String>('auto-crop-has-answers'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                    color:
                        controller.hasAnswers ? palette?.text : palette?.muted,
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
                color:
                    controller.skipPages.isNotEmpty ? danger : palette?.muted,
              ),
              const SizedBox(width: 10),
              Text(
                'Skip Pages (Optional)',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: controller.skipPages.isNotEmpty
                      ? palette?.text
                      : palette?.muted,
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
        const SizedBox(height: 12),
        _buildToggleItem(
          key: const ValueKey<String>('auto-crop-bilingual-mode'),
          icon: Icons.g_translate_rounded,
          title: 'Bilingual Mode (द्विभाषी)',
          subtitle:
              'Enable side-by-side bilingual question stitching and download options.',
          value: controller.bilingualModeActive,
          onChanged: (value) => controller.bilingualModeActive = value,
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
      color: active ? brandColor.withValues(alpha: 0.03) : (palette?.panel ?? theme.colorScheme.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
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
        QpicDropdownField<NumberingMode>(
          key: const ValueKey<String>('auto-crop-numbering'),
          value: controller.numbering,
          prefixIcon: Icon(
            Icons.format_list_numbered_rounded,
            size: 18,
            color: palette?.muted,
          ),
          items: NumberingMode.values.map((mode) {
            return QpicDropdownItem<NumberingMode>(
              value: mode,
              label: mode.label,
            );
          }).toList(),
          onChanged: (mode) {
            controller.numbering = mode;
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
        QpicDropdownField<LayoutColumnsMode>(
          key: const ValueKey<String>('auto-crop-layout-columns'),
          value: controller.layoutColumns,
          prefixIcon: Icon(
            Icons.view_column_rounded,
            size: 18,
            color: palette?.muted,
          ),
          items: LayoutColumnsMode.values.map((mode) {
            return QpicDropdownItem<LayoutColumnsMode>(
              value: mode,
              label: mode.label,
            );
          }).toList(),
          onChanged: (mode) {
            controller.layoutColumns = mode;
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

    return FilledButton.icon(
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
          : Icon(
              smartMode ? Icons.travel_explore_rounded : Icons.crop_rounded),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: palette?.brand ?? const Color(0xFF7C6CFF),
        foregroundColor: Colors.white,
        disabledBackgroundColor: palette?.border ?? theme.dividerColor,
        disabledForegroundColor: palette?.mutedAlt,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
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
        side: BorderSide.none,
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

class _AccuracySettingsPanel extends StatefulWidget {
  const _AccuracySettingsPanel({required this.controller});

  final AutoCropController controller;

  @override
  State<_AccuracySettingsPanel> createState() => _AccuracySettingsPanelState();
}

class _AccuracySettingsPanelState extends State<_AccuracySettingsPanel> {
  bool _testerOpen = false;
  bool _testing = false;
  String? _error;
  final _sampleController = TextEditingController(
    text:
        "1. Sample Question\nQuestion text...\n2. Another Question\na) Option A\n3) Third Question",
  );
  List<RegexMatchResult> _results = [];

  @override
  void dispose() {
    _sampleController.dispose();
    super.dispose();
  }

  Future<void> _runRegexTest() async {
    final client = widget.controller.apiClient;
    if (client == null) {
      setState(() {
        _error = "Engine not connected. Cannot run test.";
      });
      return;
    }

    final pattern = widget.controller.customRegex;
    if (pattern.isEmpty) {
      setState(() {
        _error = "Please enter a custom regex pattern first.";
      });
      return;
    }

    setState(() {
      _testing = true;
      _error = null;
      _results = [];
    });

    try {
      final lines = _sampleController.text.split('\n');
      final response = await client.testRegex(
        pattern: pattern,
        sampleLines: lines,
      );
      setState(() {
        _results = response.results;
        _testing = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _testing = false;
      });
    }
  }

  Future<void> _openEnhancementPreview(BuildContext context) async {
    final client = widget.controller.apiClient;
    if (client == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final jobId = await widget.controller.stashForPreview();
      if (!mounted) return;
      Navigator.of(context).pop(); // Dismiss spinner

      if (jobId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to stash PDF for preview.')),
        );
        return;
      }

      // Open the preview dialog
      await showDialog(
        context: context,
        builder: (context) => EnhancementPreviewDialog(
          apiClient: client,
          jobId: jobId,
          totalPages: widget.controller.previewPages?.length ??
              widget.controller.analyzeResult?.totalPages ??
              1,
          initialContrast: widget.controller.contrast,
          initialBrightness: widget.controller.brightness,
          initialWatermarkThreshold: widget.controller.watermarkThreshold,
          initialBinarize: widget.controller.binarize,
          initialDeskew: widget.controller.deskew,
          onApply: (contrast, brightness, watermark, binarize, deskew) {
            widget.controller.contrast = contrast;
            widget.controller.brightness = brightness;
            widget.controller.watermarkThreshold = watermark;
            widget.controller.binarize = binarize;
            widget.controller.deskew = deskew;
          },
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Dismiss spinner
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error stashing PDF: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey<String>('auto-crop-accuracy-settings-tile'),
        title: Text(
          'Enhancement / Accuracy Settings',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: palette?.text ?? theme.colorScheme.onSurface,
          ),
        ),
        leading: Icon(Icons.tune_rounded, color: brand, size: 20),
        childrenPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: <Widget>[
          if (widget.controller.hasFile)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.preview_rounded, size: 16),
                  label: const Text('Live Enhancement Preview'),
                  onPressed: () => _openEnhancementPreview(context),
                ),
              ),
            ),
          _SliderField(
            label: 'Contrast Scale',
            subtitle: 'Scale text contrast to improve OCR detection.',
            value: widget.controller.contrast,
            min: 0.5,
            max: 3.0,
            divisions: 25,
            displayValue: widget.controller.contrast.toStringAsFixed(2),
            onChanged: (val) => widget.controller.contrast = val,
          ),
          const SizedBox(height: 16),
          _SliderField(
            label: 'Brightness Scale',
            subtitle: 'Scale brightness to correct over/under-exposed scans.',
            value: widget.controller.brightness,
            min: 0.5,
            max: 2.0,
            divisions: 15,
            displayValue: widget.controller.brightness.toStringAsFixed(2),
            onChanged: (val) => widget.controller.brightness = val,
          ),
          const SizedBox(height: 16),
          _SliderField(
            label: 'Watermark Filter',
            subtitle: 'Filter light gray backgrounds / watermark artifacts.',
            value: widget.controller.watermarkThreshold.toDouble(),
            min: 0,
            max: 255,
            divisions: 255,
            displayValue: widget.controller.watermarkThreshold == 255
                ? 'Off'
                : '${widget.controller.watermarkThreshold}',
            onChanged: (val) =>
                widget.controller.watermarkThreshold = val.round(),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Binarize (Pure B&W)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            subtitle: const Text('Render page to high-contrast monochrome',
                style: TextStyle(fontSize: 11.5)),
            value: widget.controller.binarize,
            onChanged: (val) => widget.controller.binarize = val,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Deskew Pages',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            subtitle: const Text('Detect and straighten scan skew tilt',
                style: TextStyle(fontSize: 11.5)),
            value: widget.controller.deskew,
            onChanged: (val) => widget.controller.deskew = val,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey<String>('auto-crop-custom-regex'),
            controller: TextEditingController(
                text: widget.controller.customRegex)
              ..selection = TextSelection.fromPosition(
                  TextPosition(offset: widget.controller.customRegex.length)),
            decoration: InputDecoration(
              labelText: 'Custom Question Regex',
              hintText: r'e.g. ^\s*(\d{1,3})\s*-\s*',
              helperText:
                  'Custom expression to match question numbering starts',
              helperMaxLines: 2,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              suffixIcon: widget.controller.apiClient != null
                  ? IconButton(
                      icon: const Icon(Icons.bug_report_outlined),
                      tooltip: 'Test Regex Pattern',
                      onPressed: () =>
                          setState(() => _testerOpen = !_testerOpen),
                    )
                  : null,
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (val) => widget.controller.customRegex = val,
          ),
          if (_testerOpen) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    palette?.panelAlt ?? theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: palette?.borderSoft ?? theme.dividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Interactive Regex Tester',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: palette?.text ?? theme.colorScheme.onSurface,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () => setState(() => _testerOpen = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _sampleController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Sample Text Lines',
                      hintText: 'Enter test lines here...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_testing)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        FilledButton.icon(
                          icon: const Icon(Icons.play_arrow_rounded, size: 16),
                          label: const Text('Run Test'),
                          onPressed: _runRegexTest,
                        ),
                      if (_error != null)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color:
                                    palette?.danger ?? theme.colorScheme.error,
                                fontSize: 11,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Results:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final res = _results[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  res.matched
                                      ? Icons.check_circle_outline
                                      : Icons.cancel_outlined,
                                  color:
                                      res.matched ? Colors.green : Colors.red,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    res.line,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: palette?.text ??
                                          theme.colorScheme.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (res.matched)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: brand.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Q: ${res.qNum}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: brand,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          _SliderField(
            label: 'ML Confidence Threshold',
            subtitle: 'Filter local ML model box detection score.',
            value: widget.controller.mlConfidence,
            min: 0.1,
            max: 1.0,
            divisions: 18,
            displayValue: '${(widget.controller.mlConfidence * 100).round()}%',
            onChanged: (val) => widget.controller.mlConfidence = val,
          ),
        ],
      ),
    );
  }
}

class _SliderField extends StatelessWidget {
  const _SliderField({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(subtitle,
                    style: TextStyle(fontSize: 11, color: palette?.muted)),
              ],
            ),
            Text(
              displayValue,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: palette?.brand ?? theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _BatchDropZone extends StatelessWidget {
  const _BatchDropZone({
    required this.onPickFiles,
    required this.queue,
    required this.palette,
    this.isExpanded = false,
  });

  final VoidCallback? onPickFiles;
  final BatchQueueController? queue;
  final QpicPalette? palette;
  final bool isExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;

    return DropFileTarget(
      acceptedExtensions: const ['pdf'],
      allowMultiple: true,
      enabled: onPickFiles != null && queue != null && !queue!.isProcessing,
      onAccepted: (files) {
        if (queue != null && !queue!.isProcessing) {
          queue!.addFiles(files);
        }
      },
      onRejected: (msg) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      },
      child: _HoverDropZone(
        key: const ValueKey<String>('auto-crop-batch-dropzone'),
        enabled: onPickFiles != null && queue != null && !queue!.isProcessing,
        onTap: onPickFiles,
        builder: (context, hovered) {
          final bool active = hovered &&
              onPickFiles != null &&
              queue != null &&
              !queue!.isProcessing;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: EdgeInsets.symmetric(
              horizontal: 20,
              vertical: isExpanded ? 64 : 24,
            ),
            decoration: BoxDecoration(
              color: active
                  ? brand.withValues(alpha: 0.08)
                  : (palette?.field ??
                      theme.colorScheme.surfaceContainerHighest),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? brand : (palette?.border ?? theme.dividerColor),
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  color: brand,
                  size: isExpanded ? 48 : 32,
                ),
                const SizedBox(height: 12),
                Text(
                  'Drop multiple PDFs here or click to browse',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isExpanded ? 15 : 14,
                    fontWeight: FontWeight.w700,
                    color: palette?.text ?? theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Supports sequential batch processing of multiple files',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    color:
                        palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isExpanded) ...[
                  const SizedBox(height: 24),
                  Divider(
                      color: (palette?.borderSoft ?? theme.dividerColor)
                          .withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  _buildTipItem(
                    context,
                    Icons.settings_suggest_outlined,
                    'Configure settings on the left panel first.',
                  ),
                  const SizedBox(height: 12),
                  _buildTipItem(
                    context,
                    Icons.play_circle_outline_rounded,
                    'Click "Process All" to start automatic cropping.',
                  ),
                  const SizedBox(height: 12),
                  _buildTipItem(
                    context,
                    Icons.download_done_rounded,
                    'Download final cropped ZIP archives sequentially.',
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTipItem(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 16,
            color: palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.left,
          ),
        ),
      ],
    );
  }
}

class _BatchQueueList extends StatelessWidget {
  const _BatchQueueList({
    required this.controller,
    required this.palette,
  });

  final AutoCropController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final queue = controller.batchQueue;
    if (queue == null || queue.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(
            'Queue is empty. Add some PDF files to start.',
            style: TextStyle(color: palette?.muted),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final borderSoft = palette?.borderSoft ?? theme.dividerColor;

    return ListView.separated(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      itemCount: queue.items.length,
      separatorBuilder: (context, index) =>
          Divider(color: borderSoft, height: 1),
      itemBuilder: (context, index) {
        final item = queue.items[index];
        return _BatchQueueItemTile(
          item: item,
          index: index,
          queue: queue,
          controller: controller,
          palette: palette,
        );
      },
    );
  }
}

class _BatchQueueItemTile extends StatelessWidget {
  const _BatchQueueItemTile({
    required this.item,
    required this.index,
    required this.queue,
    required this.controller,
    required this.palette,
  });

  final BatchQueueItem item;
  final int index;
  final BatchQueueController queue;
  final AutoCropController controller;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final successColor = palette?.success ?? Colors.green;
    final errorColor = palette?.danger ?? Colors.red;
    final brand = palette?.brand ?? theme.colorScheme.primary;

    Widget statusIcon;
    switch (item.status) {
      case BatchItemStatus.pending:
        statusIcon =
            Icon(Icons.access_time_rounded, color: palette?.muted, size: 18);
        break;
      case BatchItemStatus.processing:
        statusIcon = SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(brand),
          ),
        );
        break;
      case BatchItemStatus.done:
        statusIcon =
            Icon(Icons.check_circle_rounded, color: successColor, size: 18);
        break;
      case BatchItemStatus.error:
        statusIcon = Icon(Icons.error_rounded, color: errorColor, size: 18);
        break;
    }

    final double kb = item.bytes.length / 1024;
    final String sizeText = kb > 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '${kb.toStringAsFixed(0)} KB';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          statusIcon,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.file.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: palette?.text ?? theme.colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.errorText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.errorText!,
                    style: TextStyle(
                      fontSize: 11,
                      color: errorColor,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ] else ...[
                  const SizedBox(height: 2),
                  Text(
                    sizeText,
                    style: TextStyle(
                      fontSize: 11,
                      color: palette?.mutedAlt ??
                          theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (item.status == BatchItemStatus.done && item.result != null) ...[
            const SizedBox(width: 8),
            Text(
              _formatItemCounts(item.result!),
              style: TextStyle(
                fontSize: 11,
                color: palette?.mutedAlt ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
            IconButton(
              icon: Icon(Icons.download_rounded, color: successColor, size: 18),
              tooltip: 'Download ZIP',
              onPressed: () async {
                final ds = controller.downloadService;
                if (ds != null) {
                  await queue.downloadItem(
                    index,
                    ds,
                    controller.questionPrefix,
                    controller.solutionPrefix,
                  );
                }
              },
            ),
          ],
          if (!queue.isProcessing)
            IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  color: palette?.muted, size: 18),
              tooltip: 'Remove',
              onPressed: () => queue.removeFile(index),
            ),
        ],
      ),
    );
  }

  String _formatItemCounts(CropResponse result) {
    final parts = <String>[];
    if (result.questionsCount > 0) {
      parts.add('${result.questionsCount}Q');
    }
    if (result.solutionsCount > 0) {
      parts.add('${result.solutionsCount}S');
    }
    return parts.isEmpty ? '0 items' : parts.join(' · ');
  }
}

class _BatchQueuePanel extends StatelessWidget {
  const _BatchQueuePanel({
    required this.controller,
    required this.palette,
    required this.onPickFile,
  });

  final AutoCropController controller;
  final QpicPalette? palette;
  final VoidCallback? onPickFile;

  @override
  Widget build(BuildContext context) {
    final queue = controller.batchQueue;
    final theme = Theme.of(context);
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final borderSoft = palette?.borderSoft ?? theme.dividerColor;

    final bool hasItems = queue != null && queue.items.isNotEmpty;
    final bool processing = queue?.isProcessing ?? false;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Batch Processing Queue',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (hasItems && !processing)
                  TextButton.icon(
                    icon: const Icon(Icons.clear_all_rounded, size: 16),
                    label: const Text('Clear Queue'),
                    onPressed: () => queue.clear(),
                    style: TextButton.styleFrom(
                      foregroundColor: palette?.muted,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (hasItems) ...[
              _BatchDropZone(
                onPickFiles: onPickFile,
                queue: queue,
                palette: palette,
                isExpanded: false,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _BatchQueueList(
                  controller: controller,
                  palette: palette,
                ),
              ),
              const SizedBox(height: 16),
              if (processing) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Processing file ${queue.currentIndex + 1} of ${queue.items.length}...',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      '${(queue.progress * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: brand,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: queue.progress,
                    color: brand,
                    backgroundColor: brand.withValues(alpha: 0.12),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key:
                          const ValueKey<String>('auto-crop-batch-process-all'),
                      icon: processing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Icon(Icons.play_circle_fill_rounded,
                              size: 18),
                      label: Text(processing ? 'Processing...' : 'Process All'),
                      onPressed: processing || controller.apiClient == null
                          ? null
                          : () {
                              final guard = controller.validateSubmission();
                              if (guard != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(guard)),
                                );
                                return;
                              }
                              queue.processAll(
                                client: controller.apiClient!,
                                dpi: controller.dpi,
                                padding: controller.padding,
                                markerStyle: controller.markerStyle,
                                hasQuestions: controller.hasQuestions,
                                questionPages: controller.hasQuestions
                                    ? controller.questionPages
                                    : null,
                                hasAnswers: controller.hasAnswers,
                                answerPages: controller.hasAnswers
                                    ? controller.answerPages
                                    : null,
                                skipPages: controller.skipPages.isNotEmpty
                                    ? controller.skipPages
                                    : null,
                                questionPrefix: controller.questionPrefix,
                                solutionPrefix: controller.solutionPrefix,
                                startNumber: controller.startNumber,
                                imageFormat: controller.imageFormatValue,
                                jpgQuality: controller.jpgQuality,
                                useAi: controller.useAi,
                                answerSheet: controller.answerSheet,
                                layoutColumns: controller.layoutColumnsValue,
                                binarize: controller.binarize,
                                contrast: controller.contrast,
                                brightness: controller.brightness,
                                watermarkThreshold:
                                    controller.watermarkThreshold,
                                deskew: controller.deskew,
                                customRegex: controller.customRegex,
                                confidence: controller.mlConfidence,
                              );
                            },
                    ),
                  ),
                  if (queue.hasSuccessfulItems) ...[
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      key: const ValueKey<String>(
                          'auto-crop-batch-download-all'),
                      icon: const Icon(Icons.download_for_offline_rounded,
                          size: 18),
                      label: const Text('Download All'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: palette?.success ?? Colors.green,
                        side: BorderSide(
                            color: (palette?.success ?? Colors.green)
                                .withValues(alpha: 0.4),
                            width: 1.5),
                      ),
                      onPressed: () async {
                        final ds = controller.downloadService;
                        if (ds != null) {
                          await queue.downloadAll(
                            ds,
                            controller.questionPrefix,
                            controller.solutionPrefix,
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            ] else
              Expanded(
                child: _BatchDropZone(
                  onPickFiles: onPickFile,
                  queue: queue,
                  palette: palette,
                  isExpanded: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
