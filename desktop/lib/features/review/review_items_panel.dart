// Review Items Panel (`review_items_panel.dart`) — the detected-items list.
//
// The right-hand list of EVERY detected/drawn item on the Review Canvas,
// faithfully reproducing the web UI's `renderItemList()` (`static/index.html`)
// which sits beneath the "Items to Fix" notes. Where [ReviewNotesPanel] only
// surfaces the engine's advisories, this panel answers "what did detection
// find, and how many?" and gives per-item controls:
//
//   * A count badge of the total number of items (web `#itemCount`).
//   * One row per item showing `<prefix><q_num>` and a sub-line that is either
//     the flag reason (flagged items), a "N parts (stitched top→bottom)" hint
//     (multi-segment items), or "Question/Solution • page N".
//   * A **Re-select** button that enters additive re-select on the item (web
//     `.it-fix` → `startEditing`), and a delete (×) that removes the item
//     (web `.it-del`).
//   * For multi-segment items, a reorderable "Parts" list (a, b, c…) with
//     up/down controls that fix the stitch order (web `.item-parts` /
//     `moveSegment`).
//
// Row state mirrors the web CSS: a `manual` item gets a brand-tinted border, a
// `flagged` item a warn-tinted border, and the item currently being
// re-selected the brand ring — read from [QpicPalette].
//
// Engine boundary (Req 1.5): ZERO engine logic here. This widget only reads the
// items the controller already holds and drives re-select / delete / reorder
// through the controller; it computes no detection, crop, or geometry.

import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import '../../models/crop.dart';
import 'crop_preview_dialog.dart';
import 'review_controller.dart';

/// Renders the full detected-items list with per-item Re-select/delete and
/// part reordering, mirroring the web `renderItemList()`.
class ReviewItemsPanel extends StatelessWidget {
  const ReviewItemsPanel({
    super.key,
    required this.controller,
    this.questionPrefix = 'Q',
    this.solutionPrefix = 'S',
  });

  /// The session controller exposing [ReviewController.items] and the
  /// re-select/delete/reorder operations.
  final ReviewController controller;

  /// Box-label prefixes carried from the active tool's output config.
  final String questionPrefix;
  final String solutionPrefix;

  @override
  Widget build(BuildContext context) {
    final QpicPalette palette =
        Theme.of(context).extension<QpicPalette>() ?? QpicPalette.dark;

    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<AnalyzedItem> items = controller.items;
        return Column(
          key: const ValueKey<String>('review-items-panel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ItemsHeader(palette: palette, count: items.length),
            const SizedBox(height: 8),
            if (items.isEmpty)
              _EmptyItems(palette: palette)
            else
              for (int i = 0; i < items.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                  child: _ItemRow(
                    key: ValueKey<String>('review-item-$i'),
                    palette: palette,
                    item: items[i],
                    index: i,
                    editing: controller.editingIndex == i,
                    questionPrefix: questionPrefix,
                    solutionPrefix: solutionPrefix,
                    onPreview: () => _openPreview(context, i),
                    onReselect: () => controller.startReselectForItem(i),
                    onDelete: () => controller.deleteItem(i),
                    onMoveUp: (int seg) => controller.moveSegment(i, seg, -1),
                    onMoveDown: (int seg) => controller.moveSegment(i, seg, 1),
                  ),
                ),
          ],
        );
      },
    );
  }

  /// Opens the per-item crop preview, but only when the engine is bound (the
  /// preview is rendered server-side). Without an engine the action is a no-op.
  void _openPreview(BuildContext context, int index) {
    if (controller.apiClient == null) return;
    CropPreviewDialog.open(
      context,
      controller: controller,
      itemIndex: index,
      questionPrefix: questionPrefix,
      solutionPrefix: solutionPrefix,
    );
  }
}

/// The "Detected items" header with a total count badge (web `#itemCount`).
class _ItemsHeader extends StatelessWidget {
  const _ItemsHeader({required this.palette, required this.count});

  final QpicPalette palette;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('review-items-head'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: <Widget>[
          Text(
            'Detected items',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: palette.text,
            ),
          ),
          const Spacer(),
          Container(
            key: const ValueKey<String>('review-items-count'),
            constraints: const BoxConstraints(minWidth: 22),
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.brand,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The advisory shown when no items have been detected/drawn yet (the Manual
/// Crop start state, and the rare empty Smart result).
class _EmptyItems extends StatelessWidget {
  const _EmptyItems({required this.palette});

  final QpicPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('review-items-empty'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: palette.borderSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.crop_free, size: 16, color: palette.muted),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'No items yet. Draw a box on the page to add one.',
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single item row: label + sub-line, a Re-select and delete control, and —
/// for multi-segment items — a reorderable parts list (web `.item-row`).
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.palette,
    required this.item,
    required this.index,
    required this.editing,
    required this.questionPrefix,
    required this.solutionPrefix,
    required this.onPreview,
    required this.onReselect,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final QpicPalette palette;
  final AnalyzedItem item;
  final int index;
  final bool editing;
  final String questionPrefix;
  final String solutionPrefix;
  final VoidCallback onPreview;
  final VoidCallback onReselect;
  final VoidCallback onDelete;
  final ValueChanged<int> onMoveUp;
  final ValueChanged<int> onMoveDown;

  @override
  Widget build(BuildContext context) {
    final String prefix = item.isSolution ? solutionPrefix : questionPrefix;
    final String kind = item.isSolution ? 'Solution' : 'Question';
    final bool multi = item.segments.length > 1;
    final bool manual = item.source == 'manual';

    // Border color encodes state, matching the web CSS precedence:
    // editing → brand ring; flagged → warn; manual → brand; else soft border.
    final Color borderColor = editing
        ? palette.brand
        : item.flagged
            ? Color.alphaBlend(palette.warn.withValues(alpha: 0.45), palette.border)
            : manual
                ? Color.alphaBlend(
                    palette.brand.withValues(alpha: 0.45), palette.border)
                : palette.borderSoft;

    final String sub = _subLine(item, kind, multi);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: editing ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '$prefix${item.qNum}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      sub,
                      style: TextStyle(fontSize: 11, color: palette.mutedAlt),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _PreviewButton(
                key: ValueKey<String>('review-item-preview-$index'),
                palette: palette,
                onPressed: onPreview,
              ),
              const SizedBox(width: 6),
              _ReselectButton(
                key: ValueKey<String>('review-item-reselect-$index'),
                palette: palette,
                onPressed: onReselect,
              ),
              const SizedBox(width: 6),
              _DeleteButton(
                key: ValueKey<String>('review-item-delete-$index'),
                palette: palette,
                onPressed: onDelete,
              ),
            ],
          ),
          if (multi) ...<Widget>[
            const SizedBox(height: 8),
            _PartsList(
              palette: palette,
              item: item,
              prefix: prefix,
              onMoveUp: onMoveUp,
              onMoveDown: onMoveDown,
            ),
          ],
        ],
      ),
    );
  }

  /// The row's sub-line, mirroring the web `renderItemList` precedence: a
  /// flagged item shows its reason; a multi-part item shows the stitch hint;
  /// otherwise the kind + page(s).
  static String _subLine(AnalyzedItem item, String kind, bool multi) {
    if (item.flagged && (item.flagReason?.isNotEmpty ?? false)) {
      return item.flagReason!;
    }
    if (multi) {
      return '$kind • ${item.segments.length} parts '
          '(stitched top→bottom in this order)';
    }
    final List<int> pages =
        item.segments.map((QuestionSegment s) => s.page).toSet().toList()
          ..sort();
    final String pageList = pages.join(', ');
    return '$kind • page $pageList';
  }
}

/// The reorderable "Parts" sub-list for a multi-segment item (web
/// `.item-parts`): each part gets a letter (a, b, c…) in stitch order plus
/// up/down controls.
class _PartsList extends StatelessWidget {
  const _PartsList({
    required this.palette,
    required this.item,
    required this.prefix,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final QpicPalette palette;
  final AnalyzedItem item;
  final String prefix;
  final ValueChanged<int> onMoveUp;
  final ValueChanged<int> onMoveDown;

  @override
  Widget build(BuildContext context) {
    final int count = item.segments.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: palette.border,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'PARTS — REORDER TO FIX THE STITCH ORDER',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: palette.mutedAlt,
            ),
          ),
          const SizedBox(height: 4),
          for (int s = 0; s < count; s++)
            Padding(
              padding: EdgeInsets.only(top: s == 0 ? 0 : 4),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: palette.brand.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      String.fromCharCode(97 + s),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: palette.brand,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$prefix${item.qNum}${String.fromCharCode(97 + s)} • '
                      'page ${item.segments[s].page}',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ),
                  _PartMoveButton(
                    icon: Icons.arrow_upward_rounded,
                    tooltip: 'Move up',
                    palette: palette,
                    onPressed: s == 0 ? null : () => onMoveUp(s),
                  ),
                  const SizedBox(width: 4),
                  _PartMoveButton(
                    icon: Icons.arrow_downward_rounded,
                    tooltip: 'Move down',
                    palette: palette,
                    onPressed: s == count - 1 ? null : () => onMoveDown(s),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The "Preview" button: opens a server-rendered crop preview of the item, so
/// the user sees exactly how it will look once cropped.
class _PreviewButton extends StatelessWidget {
  const _PreviewButton({
    super.key,
    required this.palette,
    required this.onPressed,
  });

  final QpicPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Preview crop',
      child: Material(
        color: palette.field,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.border),
            ),
            child: Icon(Icons.visibility_outlined, size: 14, color: palette.brand),
          ),
        ),
      ),
    );
  }
}

/// The brand-outlined "Re-select" button (web `.it-fix`).
class _ReselectButton extends StatelessWidget {
  const _ReselectButton({
    super.key,
    required this.palette,
    required this.onPressed,
  });

  final QpicPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Re-select region',
      child: Material(
        color: palette.field,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.border),
            ),
            child: Text(
              'Re-select',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: palette.brand,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The danger-tinted delete (×) control (web `.it-del`).
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    super.key,
    required this.palette,
    required this.onPressed,
  });

  final QpicPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Remove',
      child: Material(
        color: palette.field,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.border),
            ),
            child: Icon(Icons.close_rounded, size: 14, color: palette.danger),
          ),
        ),
      ),
    );
  }
}

/// A small up/down reorder control for a part (web `.pr-move`). Disabled at the
/// ends of the list.
class _PartMoveButton extends StatelessWidget {
  const _PartMoveButton({
    required this.icon,
    required this.tooltip,
    required this.palette,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final QpicPalette palette;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: palette.field,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(5),
          child: Opacity(
            opacity: enabled ? 1.0 : 0.35,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: palette.border),
              ),
              child: Icon(icon, size: 13, color: palette.text),
            ),
          ),
        ),
      ),
    );
  }
}
