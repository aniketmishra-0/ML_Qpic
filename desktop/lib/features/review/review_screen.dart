// Review Canvas host screen (Req 6.2, 6.3, 6.4, 6.5).
//
// [ReviewScreen] is the full-window surface that hosts the high-risk
// [ReviewCanvas] together with everything around it that the Smart Auto Crop
// (and, later, Manual Crop) review flow needs: page navigation, zoom controls,
// the answer-sheet advisory, a collapsible [ReviewNotesPanel], and a slim
// status bar. It is opened by the Auto Crop tool after a successful
// `POST /api/analyze` — regardless of the engine's `needs_review` flag
// (Req 6.2) — and binds to a [ReviewController] that already holds the returned
// pages, items, notes, and `answer_key_count`.
//
// Engine boundary (Req 1.5, 6.3): each page is a SERVER-RENDERED PNG. The
// canvas loads it from the engine-provided `preview_url` joined onto Base_URL
// via [previewUrlResolver]; nothing here rasterizes a PDF or computes any crop
// geometry. The answer-sheet message is read straight from the engine's
// `answer_key_count` (Req 6.4, 6.5).
//
// The finalize + download-from-review affordances (task 12.6) are wired through
// [onFinalize] and the controller's download seams.

import 'package:flutter/material.dart';

import '../../core/download_service.dart';
import '../../core/theme_controller.dart';
import '../auto_crop/auto_crop_controller.dart' show CropArchive;
import 'review_canvas.dart';
import 'review_controller.dart';
import 'review_items_panel.dart';
import 'review_notes_panel.dart';

/// Full-window Review Canvas host for the Smart Auto Crop / Manual Crop flows.
///
/// Binds to [controller] (already loaded from the analyze / prepare-manual
/// response) and renders the canvas, page navigation, zoom controls, the
/// answer-sheet advisory (Req 6.4/6.5), and the collapsible notes panel
/// (Req 10).
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.controller,
    this.previewUrlResolver,
    this.questionPrefix = 'Q',
    this.solutionPrefix = 'S',
    this.onClose,
    this.onFinalize,
  });

  /// The session controller exposing the pages, items, notes, view transform,
  /// and `answerKeyCount` to render.
  final ReviewController controller;

  /// Joins an engine `preview_url` onto the live Base_URL (Req 6.3). When null
  /// the `preview_url` is used verbatim (e.g. in offline widget tests).
  final PreviewUrlResolver? previewUrlResolver;

  /// Box-label prefixes carried from the active tool's output config.
  final String questionPrefix;
  final String solutionPrefix;

  /// Invoked when the user leaves the review surface (e.g. a Back affordance).
  /// When null the Back control is hidden.
  final VoidCallback? onClose;

  /// Invoked when the user confirms the reviewed set. Wired to the
  /// `POST /api/finalize` + download flow; when null the Finalize control is
  /// disabled.
  final VoidCallback? onFinalize;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  /// Whether the right-hand notes panel is shown. Toggled from the toolbar so
  /// the canvas can take the full width when the user wants more room.
  bool _notesOpen = true;

  void _toggleNotes() => setState(() => _notesOpen = !_notesOpen);

  @override
  Widget build(BuildContext context) {
    final QpicPalette palette =
        Theme.of(context).extension<QpicPalette>() ?? QpicPalette.dark;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? _) {
        return Scaffold(
          backgroundColor: palette.background,
          body: SafeArea(
            child: Column(
              children: <Widget>[
                _ReviewToolbar(
                  controller: widget.controller,
                  palette: palette,
                  onClose: widget.onClose,
                  onFinalize: widget.onFinalize,
                  notesOpen: _notesOpen,
                  onToggleNotes: _toggleNotes,
                ),
                _AnswerSheetAdvisory(
                    controller: widget.controller, palette: palette),
                _FinalizeErrorBanner(
                    controller: widget.controller, palette: palette),
                _FinalizeDownloadBar(
                    controller: widget.controller,
                    palette: palette,
                    questionPrefix: widget.questionPrefix,
                    solutionPrefix: widget.solutionPrefix),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: Container(
                          color: palette.backgroundAlt,
                          padding: const EdgeInsets.all(12),
                          child: ReviewCanvas(
                            key: const ValueKey<String>('review-canvas'),
                            controller: widget.controller.canvas,
                            previewUrlResolver: widget.previewUrlResolver,
                            questionPrefix: widget.questionPrefix,
                            solutionPrefix: widget.solutionPrefix,
                          ),
                        ),
                      ),
                      _NotesSidebar(
                        controller: widget.controller,
                        palette: palette,
                        open: _notesOpen,
                        questionPrefix: widget.questionPrefix,
                        solutionPrefix: widget.solutionPrefix,
                      ),
                    ],
                  ),
                ),
                _ReviewStatusBar(
                    controller: widget.controller, palette: palette),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Top toolbar: Back, page navigation, zoom controls, re-select Done, the
/// Finalize affordance, and a notes-panel toggle.
class _ReviewToolbar extends StatelessWidget {
  const _ReviewToolbar({
    required this.controller,
    required this.palette,
    required this.onClose,
    required this.onFinalize,
    required this.notesOpen,
    required this.onToggleNotes,
  });

  final ReviewController controller;
  final QpicPalette palette;
  final VoidCallback? onClose;
  final VoidCallback? onFinalize;
  final bool notesOpen;
  final VoidCallback onToggleNotes;

  @override
  Widget build(BuildContext context) {
    final int pageCount = controller.pages.length;
    final int pageNumber = controller.currentPageNumber;
    final int displayIndex = pageCount == 0 ? 0 : controller.currentPageIndex + 1;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.appBar,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: <Widget>[
          if (onClose != null)
            _RoundedIconButton(
              valueKey: 'review-back',
              tooltip: 'Back',
              icon: Icons.arrow_back_rounded,
              palette: palette,
              onPressed: onClose,
            ),
          const SizedBox(width: 4),
          Text(
            'Review detections',
            key: const ValueKey<String>('review-title'),
            style: TextStyle(
              color: palette.appBarText,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const Spacer(),
          // Page navigation grouped in a soft pill (Req 8.12; controller clamps).
          _ToolbarGroup(
            palette: palette,
            children: <Widget>[
              _RoundedIconButton(
                valueKey: 'review-prev-page',
                tooltip: 'Previous page',
                icon: Icons.chevron_left_rounded,
                palette: palette,
                dense: true,
                onPressed: controller.canvas.isFirstPage || pageCount == 0
                    ? null
                    : controller.previousPage,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  pageCount == 0
                      ? '—'
                      : 'Page $displayIndex / $pageCount  (p$pageNumber)',
                  key: const ValueKey<String>('review-page-indicator'),
                  style: TextStyle(color: palette.appBarText, fontSize: 13),
                ),
              ),
              _RoundedIconButton(
                valueKey: 'review-next-page',
                tooltip: 'Next page',
                icon: Icons.chevron_right_rounded,
                palette: palette,
                dense: true,
                onPressed: controller.canvas.isLastPage || pageCount == 0
                    ? null
                    : controller.nextPage,
              ),
            ],
          ),
          const SizedBox(width: 10),
          // Zoom controls grouped in a soft pill (Req 8.9; controller clamps).
          _ToolbarGroup(
            palette: palette,
            children: <Widget>[
              _RoundedIconButton(
                valueKey: 'review-zoom-out',
                tooltip: 'Zoom out',
                icon: Icons.zoom_out_rounded,
                palette: palette,
                dense: true,
                onPressed: () => controller.zoomBy(0.8),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '${(controller.zoom * 100).round()}%',
                  key: const ValueKey<String>('review-zoom-indicator'),
                  style: TextStyle(color: palette.appBarText, fontSize: 13),
                ),
              ),
              _RoundedIconButton(
                valueKey: 'review-zoom-in',
                tooltip: 'Zoom in',
                icon: Icons.zoom_in_rounded,
                palette: palette,
                dense: true,
                onPressed: () => controller.zoomBy(1.25),
              ),
              _RoundedIconButton(
                valueKey: 'review-zoom-reset',
                tooltip: 'Fit width',
                icon: Icons.fit_screen_rounded,
                palette: palette,
                dense: true,
                onPressed: controller.resetZoom,
              ),
            ],
          ),
          const SizedBox(width: 10),
          if (controller.isEditing)
            TextButton(
              key: const ValueKey<String>('review-done-reselect'),
              onPressed: controller.doneReselecting,
              child: const Text('Done re-selecting'),
            ),
          FilledButton.icon(
            key: const ValueKey<String>('review-finalize'),
            onPressed:
                (onFinalize == null || controller.finalizing) ? null : onFinalize,
            icon: controller.finalizing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(controller.finalizing ? 'Finalizing…' : 'Finalize'),
          ),
          const SizedBox(width: 8),
          // Notes panel toggle (collapse/expand the right sidebar).
          _RoundedIconButton(
            valueKey: 'review-toggle-notes',
            tooltip: notesOpen ? 'Hide notes' : 'Show notes',
            icon: Icons.view_sidebar_rounded,
            palette: palette,
            active: notesOpen,
            onPressed: onToggleNotes,
          ),
        ],
      ),
    );
  }
}

/// A soft rounded container that groups a set of toolbar controls (page nav,
/// zoom) so the toolbar reads as distinct clusters rather than a flat row.
class _ToolbarGroup extends StatelessWidget {
  const _ToolbarGroup({required this.palette, required this.children});

  final QpicPalette palette;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color: palette.field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// A compact rounded icon button used throughout the review toolbar. Keeps the
/// stable ValueKey the widget tests drive while giving a more polished, native
/// feel than a bare [IconButton].
class _RoundedIconButton extends StatelessWidget {
  const _RoundedIconButton({
    required this.valueKey,
    required this.tooltip,
    required this.icon,
    required this.palette,
    required this.onPressed,
    this.dense = false,
    this.active = false,
  });

  final String valueKey;
  final String tooltip;
  final IconData icon;
  final QpicPalette palette;
  final VoidCallback? onPressed;
  final bool dense;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final double size = dense ? 30 : 36;
    final Color fg = active
        ? palette.brand
        : (onPressed == null ? palette.mutedAlt : palette.appBarText);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? palette.brand.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey<String>(valueKey),
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: dense ? 18 : 20, color: fg),
          ),
        ),
      ),
    );
  }
}

/// The answer-sheet advisory banner (Req 6.4, 6.5): a positive `answer_key_count`
/// means the finalized download WILL include an answer sheet; zero (for a Smart
/// session) means it will NOT. Hidden entirely for a Manual Crop session, which
/// carries no answer key.
class _AnswerSheetAdvisory extends StatelessWidget {
  const _AnswerSheetAdvisory({required this.controller, required this.palette});

  final ReviewController controller;
  final QpicPalette palette;

  @override
  Widget build(BuildContext context) {
    final int? count = controller.answerKeyCount;
    // Manual Crop has no answer key (null) → no advisory.
    if (count == null) return const SizedBox.shrink();

    final bool willInclude = controller.finalizeWillIncludeAnswerSheet;
    final Color accent = willInclude ? palette.success : palette.muted;
    final String message = willInclude
        ? 'An answer key was detected ($count answer'
            '${count == 1 ? '' : 's'}). The finalized download WILL include an '
            'answer sheet.'
        : 'No answer key was detected. The finalized download will NOT include '
            'an answer sheet.';

    return Container(
      key: const ValueKey<String>('review-answer-sheet-advisory'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.10), palette.panel),
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            willInclude ? Icons.fact_check_outlined : Icons.info_outline,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              key: const ValueKey<String>('review-answer-sheet-message'),
              style: TextStyle(color: palette.text, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Surfaces the engine `detail` from a failed finalize (Req 6.7-style). The
/// items are retained on the canvas so the user can fix and retry (Req 7.7).
class _FinalizeErrorBanner extends StatelessWidget {
  const _FinalizeErrorBanner({required this.controller, required this.palette});

  final ReviewController controller;
  final QpicPalette palette;

  @override
  Widget build(BuildContext context) {
    final String? error = controller.finalizeError;
    if (error == null || error.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const ValueKey<String>('review-finalize-error'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(palette.danger.withValues(alpha: 0.12), palette.panel),
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: palette.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error,
              key: const ValueKey<String>('review-finalize-error-message'),
              style: TextStyle(color: palette.text, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// The post-finalize download bar (Req 11.1–11.3): a Combined download is
/// always offered once finalize succeeds, with Questions-only / Solutions-only
/// shown only when the engine reported their URLs. Each routes through
/// [ReviewController.download] → `GET /api/crop/download/{job_id}` with the
/// configured prefixes (Req 11.4).
class _FinalizeDownloadBar extends StatelessWidget {
  const _FinalizeDownloadBar({
    required this.controller,
    required this.palette,
    required this.questionPrefix,
    required this.solutionPrefix,
  });

  final ReviewController controller;
  final QpicPalette palette;
  final String questionPrefix;
  final String solutionPrefix;

  @override
  Widget build(BuildContext context) {
    if (controller.finalizeResult == null) return const SizedBox.shrink();

    return Container(
      key: const ValueKey<String>('review-finalize-download-bar'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(palette.success.withValues(alpha: 0.08), palette.panel),
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 18, color: palette.success),
          Text(
            'Crops are ready.',
            style: TextStyle(color: palette.text, fontSize: 13),
          ),
          const SizedBox(width: 4),
          // Combined is always available once finalize succeeds (Req 11.1).
          FilledButton.icon(
            key: const ValueKey<String>('review-download-combined'),
            onPressed: controller.canDownload(CropArchive.combined)
                ? () => _save(context, CropArchive.combined)
                : null,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download combined ZIP'),
          ),
          // Questions-only, only when the engine reported its URL (Req 11.2).
          if (controller.canDownload(CropArchive.questions))
            OutlinedButton.icon(
              key: const ValueKey<String>('review-download-questions'),
              onPressed: () => _save(context, CropArchive.questions),
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('Questions only'),
            ),
          // Solutions-only, only when the engine reported its URL (Req 11.3).
          if (controller.canDownload(CropArchive.solutions))
            OutlinedButton.icon(
              key: const ValueKey<String>('review-download-solutions'),
              onPressed: () => _save(context, CropArchive.solutions),
              icon: const Icon(Icons.lightbulb_outline, size: 18),
              label: const Text('Solutions only'),
            ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, CropArchive archive) async {
    final DownloadResult? result = await controller.download(archive);
    if (!context.mounted) return;
    if (result != null && result.isSaved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${result.path}')),
      );
    }
  }
}

/// Right-hand sidebar hosting the review notes panel and the detected-items
/// list (Req 10). Collapses to a zero-width strip with a smooth animation when
/// [open] is false so the canvas can take the full width.
class _NotesSidebar extends StatelessWidget {
  const _NotesSidebar({
    required this.controller,
    required this.palette,
    required this.open,
    required this.questionPrefix,
    required this.solutionPrefix,
  });

  final ReviewController controller;
  final QpicPalette palette;
  final bool open;
  final String questionPrefix;
  final String solutionPrefix;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: SizedBox(
        width: open ? 320 : 0,
        child: open
            ? Container(
                decoration: BoxDecoration(
                  color: palette.panel,
                  border: Border(left: BorderSide(color: palette.border)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      ReviewNotesPanel(controller: controller),
                      const SizedBox(height: 16),
                      ReviewItemsPanel(
                        controller: controller,
                        questionPrefix: questionPrefix,
                        solutionPrefix: solutionPrefix,
                      ),
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// A slim status bar pinned to the bottom of the review surface showing the
/// page/item summary and a keyboard-shortcut hint. Purely informational — it
/// reads from the controller and triggers no engine work.
class _ReviewStatusBar extends StatelessWidget {
  const _ReviewStatusBar({required this.controller, required this.palette});

  final ReviewController controller;
  final QpicPalette palette;

  @override
  Widget build(BuildContext context) {
    final int pageCount = controller.pages.length;
    final int itemCount = controller.items.length;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        border: Border(top: BorderSide(color: palette.borderSoft)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.description_outlined, size: 13, color: palette.muted),
          const SizedBox(width: 6),
          Text(
            '$pageCount page${pageCount == 1 ? '' : 's'} · '
            '$itemCount detection${itemCount == 1 ? '' : 's'}',
            style: TextStyle(color: palette.muted, fontSize: 11.5),
          ),
          const Spacer(),
          Text(
            'Double-click a box to re-select · scroll to zoom',
            style: TextStyle(color: palette.mutedAlt, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
