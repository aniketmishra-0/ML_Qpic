// Edit tool view — open + clickable spans (Req 15.1-15.3, 15.8) plus in-place
// editing, apply, OCR, and download (Req 15.4, 15.5, 15.6, 15.7).
//
// [EditView] renders the Edit tool backed by an [EditController]:
//
//   * Idle: a Choose-PDF prompt (also a drag-and-drop target) that opens a PDF
//     via the controller (`POST /api/tools/edit/open`).
//   * Opening: a busy indicator.
//   * Error: the engine's `detail` surfaced verbatim, with a way to retry.
//   * Ready: every page rendered from its server-rendered `preview_url`
//     (`Image.network`, Req 15.2 — no Dart PDF rasterization), with each
//     editable span overlaid as a clickable box positioned by converting its
//     PDF-point `bbox` to display px via [spanRectForPage] (Req 15.3). Clicking
//     a span turns it into an in-place text field (Req 15.4). A toolbar exposes
//     Apply (`edit/apply`, Req 15.5), Run-OCR with language + DPI controls
//     (`edit/ocr`, Req 15.6), and Download the edited / OCR'd PDF
//     (`edit/download`, Req 15.7). When the opened PDF has no selectable text
//     (`has_text == false`) a banner tells the user to add objects or run OCR
//     (Req 15.8).
//
// The view holds NO engine logic and issues NO requests directly — every action
// delegates to the [EditController]. Every interactive widget carries a stable
// `ValueKey` so the widget tests (task 18.3) can drive it.

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme_controller.dart';
import '../../../models/tools.dart';
import '../../../widgets/drop_target.dart';
import 'edit_controller.dart';
import 'edit_geometry.dart';

/// Stateless surface for the Edit tool. Listens to [controller] via an
/// [AnimatedBuilder] so the open status, page list, selected span, and action
/// state stay in sync. [onPickFile] is invoked when the user asks to choose a
/// PDF; the file-picker integration (and a follow-on call to
/// [EditController.open]) is wired by the host. [onDropFiles] receives files
/// dropped on the open prompt. Apply / OCR / Download are driven directly on
/// the controller (it owns the engine + DownloadService wiring).
class EditView extends StatelessWidget {
  const EditView({
    super.key,
    required this.controller,
    this.onPickFile,
    this.onDropFiles,
  });

  /// Backing Edit-tool state. The view mutates it only through the controller's
  /// own methods (select / edit / apply / OCR / download).
  final EditController controller;

  /// Invoked when the user taps "Choose PDF". When null the button is disabled.
  final VoidCallback? onPickFile;

  /// Invoked when files are dropped on the open prompt. When null, drops are
  /// ignored. The host filters/loads the PDF and calls [EditController.open].
  final ValueChanged<List<XFile>>? onDropFiles;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        switch (controller.status) {
          case EditStatus.idle:
            return _OpenPrompt(
              onPickFile: onPickFile,
              onDropFiles: onDropFiles,
            );
          case EditStatus.opening:
            return const _OpeningState();
          case EditStatus.error:
            return _ErrorState(
              detail: controller.errorDetail ?? 'Could not open that PDF.',
              onRetry: onPickFile,
            );
          case EditStatus.ready:
            return _ReadyState(controller: controller);
        }
      },
    );
  }
}

class _OpenPrompt extends StatelessWidget {
  const _OpenPrompt({required this.onPickFile, required this.onDropFiles});

  final VoidCallback? onPickFile;
  final ValueChanged<List<XFile>>? onDropFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    final card = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.edit_document,
                size: 48, color: palette?.brand ?? theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Edit a PDF',
              key: const ValueKey<String>('edit-title'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: palette?.text ?? theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Open a PDF to edit its text in place, or run OCR to make a scan '
              'editable. Drop a PDF here or choose one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey<String>('edit-pick-file'),
              onPressed: onPickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose PDF'),
            ),
          ],
        ),
      ),
    );

    if (onDropFiles == null) {
      return Padding(padding: const EdgeInsets.all(24), child: card);
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: DropFileTarget.pdfOnly(
        key: const ValueKey<String>('edit-drop-target'),
        onAccepted: (files) => onDropFiles!(files),
        child: card,
      ),
    );
  }
}

class _OpeningState extends StatelessWidget {
  const _OpeningState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return Center(
      key: const ValueKey<String>('edit-opening'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Opening PDF…',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.detail, required this.onRetry});

  final String detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final danger = palette?.danger ?? theme.colorScheme.error;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: danger, size: 40),
            const SizedBox(height: 12),
            Text(
              detail,
              key: const ValueKey<String>('edit-error'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: danger),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const ValueKey<String>('edit-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Choose another PDF'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadyState extends StatelessWidget {
  const _ReadyState({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final pages = controller.pages;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ReadyHeader(controller: controller),
        _EditToolbar(controller: controller),
        // When the PDF has no selectable text, guide the user to OCR (15.8).
        if (!controller.hasText) _NoTextBanner(palette: palette),
        if (controller.actionError != null)
          _ActionErrorBanner(
            message: controller.actionError!,
            palette: palette,
          ),
        Expanded(
          child: Container(
            color: palette?.background ?? theme.colorScheme.surface,
            child: ListView.separated(
              key: const ValueKey<String>('edit-page-list'),
              padding: const EdgeInsets.all(24),
              itemCount: pages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 26),
              itemBuilder: (context, index) {
                final EditPageModel page = pages[index];
                return _EditPage(
                  page: page,
                  previewUri: controller.previewUri(page),
                  spans: controller.spansForPage(page.page),
                  selectedSpanId: controller.selectedSpanId,
                  onSpanTap: controller.selectSpan,
                  textForSpan: controller.effectiveText,
                  isEdited: controller.isSpanEdited,
                  onCommitSpanText: controller.setSpanText,
                  interactive: controller.hasText,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ReadyHeader extends StatelessWidget {
  const _ReadyHeader({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final spanCount = controller.spans.length;
    final pageCount = controller.pages.length;
    final pending = controller.pendingEditCount;

    final String subtitle = controller.hasText
        ? '$spanCount editable text run${spanCount == 1 ? '' : 's'} · '
            '$pageCount page${pageCount == 1 ? '' : 's'}'
        : 'Scanned PDF (no selectable text) · '
            '$pageCount page${pageCount == 1 ? '' : 's'}';

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    controller.fileName ?? 'document.pdf',
                    key: const ValueKey<String>('edit-file-name'),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: palette?.text ?? theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    key: const ValueKey<String>('edit-subtitle'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (pending > 0)
              Container(
                key: const ValueKey<String>('edit-dirty-chip'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (palette?.warn ?? theme.colorScheme.tertiary)
                      .withAlpha(36),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '● $pending unsaved change${pending == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette?.warn ?? theme.colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The Apply / Run-OCR / Download toolbar that sits under the header. It hosts
/// the OCR language + DPI controls and the three action buttons, plus the
/// apply/OCR result summaries.
class _EditToolbar extends StatelessWidget {
  const _EditToolbar({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final applyResult = controller.applyResult;
    final ocrResult = controller.ocrResult;

    return Material(
      color: palette?.panel ?? theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _ApplyButton(controller: controller),
                _OcrLanguagesField(controller: controller),
                _OcrDpiField(controller: controller),
                _RunOcrButton(controller: controller),
                _DownloadButton(controller: controller),
              ],
            ),
            if (applyResult != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Applied ${applyResult.editsApplied} '
                'edit${applyResult.editsApplied == 1 ? '' : 's'} · '
                'download your edited PDF.',
                key: const ValueKey<String>('edit-apply-result'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.success ?? theme.colorScheme.primary,
                ),
              ),
            ],
            if (ocrResult != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                ocrResult.note.isNotEmpty
                    ? ocrResult.note
                    : 'OCR complete — ${ocrResult.pagesOcred} '
                        'page${ocrResult.pagesOcred == 1 ? '' : 's'} '
                        '(${ocrResult.languages}).',
                key: const ValueKey<String>('edit-ocr-result'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette?.success ?? theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ApplyButton extends StatelessWidget {
  const _ApplyButton({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final applying = controller.applying;
    return FilledButton.icon(
      key: const ValueKey<String>('edit-apply'),
      onPressed: controller.canApply ? () => controller.apply() : null,
      icon: applying
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.save),
      label: Text(
        controller.pendingEditCount > 0
            ? 'Apply edits (${controller.pendingEditCount})'
            : 'Apply edits',
      ),
    );
  }
}

class _OcrLanguagesField extends StatefulWidget {
  const _OcrLanguagesField({required this.controller});

  final EditController controller;

  @override
  State<_OcrLanguagesField> createState() => _OcrLanguagesFieldState();
}

class _OcrLanguagesFieldState extends State<_OcrLanguagesField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.controller.ocrLanguages);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: TextField(
        key: const ValueKey<String>('edit-ocr-languages'),
        controller: _text,
        decoration: const InputDecoration(
          labelText: 'OCR languages',
          hintText: 'e.g. eng+hin',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        onChanged: (value) => widget.controller.ocrLanguages = value,
      ),
    );
  }
}

class _OcrDpiField extends StatefulWidget {
  const _OcrDpiField({required this.controller});

  final EditController controller;

  @override
  State<_OcrDpiField> createState() => _OcrDpiFieldState();
}

class _OcrDpiFieldState extends State<_OcrDpiField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.controller.ocrDpiText);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final invalid = !widget.controller.isOcrDpiValid;
    return SizedBox(
      width: 130,
      child: TextField(
        key: const ValueKey<String>('edit-ocr-dpi'),
        controller: _text,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: 'OCR DPI',
          hintText: '${EditOcrBounds.dpiDefault}',
          errorText: invalid
              ? '${EditOcrBounds.dpiMin}–${EditOcrBounds.dpiMax}'
              : null,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: (value) => widget.controller.ocrDpiText = value,
      ),
    );
  }
}

class _RunOcrButton extends StatelessWidget {
  const _RunOcrButton({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final running = controller.ocrRunning;
    return OutlinedButton.icon(
      key: const ValueKey<String>('edit-run-ocr'),
      onPressed: controller.canRunOcr ? () => controller.runOcr() : null,
      icon: running
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.document_scanner),
      label: Text(running ? 'Running OCR…' : 'Run OCR'),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: const ValueKey<String>('edit-download'),
      onPressed: controller.canDownload ? () => controller.download() : null,
      icon: const Icon(Icons.download),
      label: const Text('Download PDF'),
    );
  }
}

class _NoTextBanner extends StatelessWidget {
  const _NoTextBanner({required this.palette});

  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = palette?.warn ?? theme.colorScheme.tertiary;
    return Container(
      key: const ValueKey<String>('edit-no-text-guidance'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      color: warn.withAlpha(28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.document_scanner_outlined, color: warn, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This PDF has no selectable text. Add objects or run OCR to edit '
              'existing text.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette?.text ?? theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionErrorBanner extends StatelessWidget {
  const _ActionErrorBanner({required this.message, required this.palette});

  final String message;
  final QpicPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = palette?.danger ?? theme.colorScheme.error;
    return Container(
      key: const ValueKey<String>('edit-action-error'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      color: danger.withAlpha(28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: danger, size: 20),
          const SizedBox(width: 10),
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

/// One rendered page with its clickable / editable span overlays.
class _EditPage extends StatelessWidget {
  const _EditPage({
    required this.page,
    required this.previewUri,
    required this.spans,
    required this.selectedSpanId,
    required this.onSpanTap,
    required this.textForSpan,
    required this.isEdited,
    required this.onCommitSpanText,
    required this.interactive,
  });

  final EditPageModel page;
  final Uri previewUri;
  final List<EditableSpanModel> spans;
  final String? selectedSpanId;
  final ValueChanged<String?> onSpanTap;
  final String Function(EditableSpanModel span) textForSpan;
  final bool Function(String id) isEdited;
  final void Function(String id, String text) onCommitSpanText;

  /// Whether spans are clickable/editable. False for a scanned PDF (no text).
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Fit-width baseline: the page fills the available width (web
          // `computeFitWidthZoom`). The overlay is sized to match.
          final Size display = displaySizeForWidth(page, constraints.maxWidth);
          if (display == Size.zero) {
            return const SizedBox.shrink();
          }
          return SizedBox(
            width: display.width,
            height: display.height,
            child: Stack(
              key: ValueKey<String>('edit-page-${page.page}'),
              children: <Widget>[
                // Server-rendered PNG preview (Req 15.2). Never a Dart-side
                // PDF rasterization (Req 1.5).
                Positioned.fill(
                  child: Image.network(
                    previewUri.toString(),
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) =>
                        const ColoredBox(color: Color(0xFFFFFFFF)),
                  ),
                ),
                // Clickable / editable span overlays (Req 15.3, 15.4).
                for (final span in spans)
                  _SpanBox(
                    span: span,
                    rect: spanRectForPage(
                      span: span,
                      page: page,
                      displaySize: display,
                    ),
                    selected: span.id == selectedSpanId,
                    edited: isEdited(span.id),
                    text: textForSpan(span),
                    interactive: interactive,
                    onTap: () => onSpanTap(span.id),
                    onCommit: (value) => onCommitSpanText(span.id, value),
                    onDismiss: () => onSpanTap(null),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A single text-span box positioned over the page preview. When not selected
/// it is a clickable highlight; when selected (and interactive) it becomes an
/// in-place [TextField] seeded with the span's current text (Req 15.4).
class _SpanBox extends StatelessWidget {
  const _SpanBox({
    required this.span,
    required this.rect,
    required this.selected,
    required this.edited,
    required this.text,
    required this.interactive,
    required this.onTap,
    required this.onCommit,
    required this.onDismiss,
  });

  final EditableSpanModel span;
  final Rect rect;
  final bool selected;
  final bool edited;
  final String text;
  final bool interactive;
  final VoidCallback onTap;
  final ValueChanged<String> onCommit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final accent = palette?.brand ?? theme.colorScheme.primary;
    final changed = palette?.warn ?? theme.colorScheme.tertiary;

    // Editing mode: an in-place text field over the span (Req 15.4).
    if (selected && interactive) {
      return Positioned(
        left: rect.left,
        top: rect.top,
        // Give the editor a little breathing room like the web input.
        width: rect.width < 60 ? 60 : rect.width,
        height: rect.height < 22 ? 22 : rect.height,
        child: _SpanEditor(
          spanId: span.id,
          initialText: text,
          accent: accent,
          onCommit: onCommit,
          onDismiss: onDismiss,
        ),
      );
    }

    final Color outline = edited ? changed : accent.withAlpha(120);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: MouseRegion(
        cursor: interactive ? SystemMouseCursors.text : MouseCursor.defer,
        child: GestureDetector(
          key: ValueKey<String>('edit-span-${span.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: interactive ? onTap : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: (edited ? changed : accent).withAlpha(edited ? 40 : 18),
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: outline, width: edited ? 1.4 : 1.0),
            ),
          ),
        ),
      ),
    );
  }
}

/// The in-place editor shown over a selected span. Commits on submit / focus
/// loss (web parity: Enter or blur commits, Escape cancels).
class _SpanEditor extends StatefulWidget {
  const _SpanEditor({
    required this.spanId,
    required this.initialText,
    required this.accent,
    required this.onCommit,
    required this.onDismiss,
  });

  final String spanId;
  final String initialText;
  final Color accent;
  final ValueChanged<String> onCommit;
  final VoidCallback onDismiss;

  @override
  State<_SpanEditor> createState() => _SpanEditorState();
}

class _SpanEditorState extends State<_SpanEditor> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initialText);
  final FocusNode _focus = FocusNode();
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    // Commit on blur unless the edit was cancelled with Escape.
    if (!_focus.hasFocus && !_cancelled) {
      widget.onCommit(_text.text);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _cancelled = true;
          widget.onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        key: ValueKey<String>('edit-span-input-${widget.spanId}'),
        controller: _text,
        focusNode: _focus,
        autofocus: true,
        maxLines: 1,
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          filled: true,
          fillColor: theme.colorScheme.surface,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: widget.accent, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: widget.accent, width: 1.5),
          ),
        ),
        onSubmitted: (value) {
          widget.onCommit(value);
          widget.onDismiss();
        },
      ),
    );
  }
}
