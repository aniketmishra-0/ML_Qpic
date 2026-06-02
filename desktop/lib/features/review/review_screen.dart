// Review Canvas host screen (Req 6.2, 6.3, 6.4, 6.5).
//
// [ReviewScreen] is the full-window surface that hosts the high-risk
// [ReviewCanvas] together with everything around it that the Smart Auto Crop
// (and, later, Manual Crop) review flow needs: page navigation, zoom controls,
// the answer-sheet advisory, and the [ReviewNotesPanel]. It is opened by the
// Auto Crop tool after a successful `POST /api/analyze` — regardless of the
// engine's `needs_review` flag (Req 6.2) — and binds to a [ReviewController]
// that already holds the returned pages, items, notes, and `answer_key_count`.
//
// Engine boundary (Req 1.5, 6.3): each page is a SERVER-RENDERED PNG. The
// canvas loads it from the engine-provided `preview_url` joined onto Base_URL
// via [previewUrlResolver]; nothing here rasterizes a PDF or computes any crop
// geometry. The answer-sheet message is read straight from the engine's
// `answer_key_count` (Req 6.4, 6.5).
//
// SCOPE: this screen wires the analyze→review ENTRY (task 12.5). The finalize
// and download from review (task 12.6) are intentionally not implemented here;
// an [onFinalize] hook is exposed for that later task to attach the
// `POST /api/finalize` flow without reworking this screen.

import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import '../auto_crop/auto_crop_controller.dart' show CropArchive;
import '../../core/download_service.dart';
import 'review_canvas.dart';
import 'review_controller.dart';
import 'review_notes_panel.dart';

/// Full-window Review Canvas host for the Smart Auto Crop / Manual Crop flows.
///
/// Binds to [controller] (already loaded from the analyze / prepare-manual
/// response) and renders the canvas, page navigation, zoom controls, the
/// answer-sheet advisory (Req 6.4/6.5), and the notes panel (Req 10).
class ReviewScreen extends StatelessWidget {
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

  /// Invoked when the user confirms the reviewed set. Wired by task 12.6 to the
  /// `POST /api/finalize` + download flow; when null the Finalize control is
  /// disabled (this task only wires the analyze→review entry).
  final VoidCallback? onFinalize;

  @override
  Widget build(BuildContext context) {
    final QpicPalette palette =
        Theme.of(context).extension<QpicPalette>() ?? QpicPalette.dark;

    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? _) {
        return Scaffold(
          backgroundColor: palette.background,
          body: SafeArea(
            child: Column(
              children: <Widget>[
                _ReviewToolbar(
                  controller: controller,
                  palette: palette,
                  onClose: onClose,
                  onFinalize: onFinalize,
                ),
                _AnswerSheetAdvisory(controller: controller, palette: palette),
                _FinalizeErrorBanner(controller: controller, palette: palette),
                _FinalizeDownloadBar(controller: controller, palette: palette),
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
                            controller: controller.canvas,
                            previewUrlResolver: previewUrlResolver,
                            questionPrefix: questionPrefix,
                            solutionPrefix: solutionPrefix,
                          ),
                        ),
                      ),
                      _NotesSidebar(controller: controller, palette: palette),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Top toolbar: Back, page navigation, zoom controls, re-select Done, and the
/// (task-12.6) Finalize affordance.
class _ReviewToolbar extends StatelessWidget {
  const _ReviewToolbar({
    required this.controller,
    required this.palette,
    required this.onClose,
    required this.onFinalize,
  });

  final ReviewController controller;
  final QpicPalette palette;
  final VoidCallback? onClose;
  final VoidCallback? onFinalize;

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
            IconButton(
              key: const ValueKey<String>('review-back'),
              tooltip: 'Back',
              color: palette.appBarText,
              icon: const Icon(Icons.arrow_back),
              onPressed: onClose,
            ),
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
          // Page navigation (Req 8.12 surfaced here; the controller clamps).
          IconButton(
            key: const ValueKey<String>('review-prev-page'),
            tooltip: 'Previous page',
            color: palette.appBarText,
            icon: const Icon(Icons.chevron_left),
            onPressed: controller.canvas.isFirstPage || pageCount == 0
                ? null
                : controller.previousPage,
          ),
          Text(
            pageCount == 0 ? '—' : 'Page $displayIndex / $pageCount  (p$pageNumber)',
            key: const ValueKey<String>('review-page-indicator'),
            style: TextStyle(color: palette.appBarText, fontSize: 13),
          ),
          IconButton(
            key: const ValueKey<String>('review-next-page'),
            tooltip: 'Next page',
            color: palette.appBarText,
            icon: const Icon(Icons.chevron_right),
            onPressed: controller.canvas.isLastPage || pageCount == 0
                ? null
                : controller.nextPage,
          ),
          const SizedBox(width: 12),
          // Zoom controls (Req 8.9; the controller clamps 0.25..6.0).
          IconButton(
            key: const ValueKey<String>('review-zoom-out'),
            tooltip: 'Zoom out',
            color: palette.appBarText,
            icon: const Icon(Icons.zoom_out),
            onPressed: () => controller.zoomBy(0.8),
          ),
          Text(
            '${(controller.zoom * 100).round()}%',
            key: const ValueKey<String>('review-zoom-indicator'),
            style: TextStyle(color: palette.appBarText, fontSize: 13),
          ),
          IconButton(
            key: const ValueKey<String>('review-zoom-in'),
            tooltip: 'Zoom in',
            color: palette.appBarText,
            icon: const Icon(Icons.zoom_in),
            onPressed: () => controller.zoomBy(1.25),
          ),
          IconButton(
            key: const ValueKey<String>('review-zoom-reset'),
            tooltip: 'Fit width',
            color: palette.appBarText,
            icon: const Icon(Icons.fit_screen),
            onPressed: controller.resetZoom,
          ),
          const SizedBox(width: 12),
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
                : const Icon(Icons.check),
            label: Text(controller.finalizing ? 'Finalizing…' : 'Finalize'),
          ),
        ],
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
  const _FinalizeDownloadBar({required this.controller, required this.palette});

  final ReviewController controller;
  final QpicPalette palette;

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

/// Right-hand sidebar hosting the review notes panel (Req 10).
class _NotesSidebar extends StatelessWidget {
  const _NotesSidebar({required this.controller, required this.palette});

  final ReviewController controller;
  final QpicPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: ReviewNotesPanel(controller: controller),
      ),
    );
  }
}
