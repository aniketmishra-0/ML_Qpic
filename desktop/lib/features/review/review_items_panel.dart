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
    this.englishQuestionPrefix = 'EQ',
    this.englishSolutionPrefix = 'ES',
    this.hindiQuestionPrefix = 'HQ',
    this.hindiSolutionPrefix = 'HS',
    this.bilingualModeActive = false,
    this.searchQuery = '',
  });

  /// The session controller exposing [ReviewController.items] and the
  /// re-select/delete/reorder operations.
  final ReviewController controller;

  /// Box-label prefixes carried from the active tool's output config.
  final String questionPrefix;
  final String solutionPrefix;
  final String englishQuestionPrefix;
  final String englishSolutionPrefix;
  final String hindiQuestionPrefix;
  final String hindiSolutionPrefix;
  final bool bilingualModeActive;

  /// The search filter query entered by the user.
  final String searchQuery;

  String _getPrefix(AnalyzedItem item) {
    if (bilingualModeActive) {
      final bool isHindi = item.isHindi ?? (item.segments.isNotEmpty
          ? (item.segments.first.xStartPct + item.segments.first.xEndPct) / 2.0 > 50.0
          : false);
      if (isHindi) {
        return item.isSolution ? hindiSolutionPrefix : hindiQuestionPrefix;
      } else {
        return item.isSolution ? englishSolutionPrefix : englishQuestionPrefix;
      }
    } else {
      return item.isSolution ? solutionPrefix : questionPrefix;
    }
  }

  @override
  Widget build(BuildContext context) {
    final QpicPalette palette =
        Theme.of(context).extension<QpicPalette>() ?? QpicPalette.dark;

    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<AnalyzedItem> allItems = controller.items;

        // Associate items with their original indices to ensure correct callbacks.
        final List<MapEntry<int, AnalyzedItem>> indexedItems =
            <MapEntry<int, AnalyzedItem>>[];
        for (int i = 0; i < allItems.length; i++) {
          final AnalyzedItem item = allItems[i];
          final String prefix = _getPrefix(item);
          final String label = (prefix + item.qNum).toLowerCase();
          final String kind = item.isSolution ? 'solution' : 'question';
          final String sub = _ItemRow._subLine(
            item,
            item.isSolution ? 'Solution' : 'Question',
            item.segments.length > 1,
          ).toLowerCase();

          final String query = searchQuery.toLowerCase();
          if (searchQuery.isEmpty ||
              label.contains(query) ||
              sub.contains(query) ||
              kind.contains(query)) {
            indexedItems.add(MapEntry<int, AnalyzedItem>(i, item));
          }
        }

        return Column(
          key: const ValueKey<String>('review-items-panel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ItemsHeader(palette: palette, count: indexedItems.length),
            const SizedBox(height: 8),
            if (controller.selectedItemIndices.length >= 2) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  key: const ValueKey<String>('review-items-merge-button'),
                  onPressed: controller.mergeSelectedItems,
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.brandBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.call_merge_rounded, size: 16),
                  label: Text(
                      'Merge Selected (${controller.selectedItemIndices.length})'),
                ),
              ),
            ],
            if (indexedItems.isEmpty)
              _EmptyItems(palette: palette)
            else
              for (int i = 0; i < indexedItems.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                  child: _ItemRow(
                    key: ValueKey<String>('review-item-${indexedItems[i].key}'),
                    palette: palette,
                    item: indexedItems[i].value,
                    index: indexedItems[i].key,
                    editing: controller.editingIndex == indexedItems[i].key,
                    selected: controller.isSelected(indexedItems[i].key),
                    onToggleSelection: () =>
                        controller.toggleSelection(indexedItems[i].key),
                    prefix: _getPrefix(indexedItems[i].value),
                    onPreview: () => _openPreview(context, indexedItems[i].key),
                    onEditQNum: () => _editNumber(context, indexedItems[i].key),
                    onReselect: () =>
                        controller.startReselectForItem(indexedItems[i].key),
                    onDelete: () => _confirmDelete(
                        context, indexedItems[i].value, indexedItems[i].key),
                    onMoveUp: (int seg) =>
                        controller.moveSegment(indexedItems[i].key, seg, -1),
                    onMoveDown: (int seg) =>
                        controller.moveSegment(indexedItems[i].key, seg, 1),
                    onDeletePart: (int seg) =>
                        controller.deleteSegment(indexedItems[i].key, seg),
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
    final item = controller.items[index];
    final prefix = _getPrefix(item);
    CropPreviewDialog.open(
      context,
      controller: controller,
      itemIndex: index,
      questionPrefix: prefix,
      solutionPrefix: prefix,
    );
  }

  /// Prompt the user with a confirmation dialog before deleting an item.
  Future<void> _confirmDelete(
      BuildContext context, AnalyzedItem item, int index) async {
    final String prefix = _getPrefix(item);
    final String label = '$prefix${item.qNum}';
    final String itemType = item.isSolution ? 'Solution' : 'Question';

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        final QpicPalette palette =
            Theme.of(context).extension<QpicPalette>() ?? QpicPalette.dark;
        return AlertDialog(
          backgroundColor: palette.panel,
          title: Text(
            'Confirm Delete',
            style: TextStyle(
                color: palette.text, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Are you sure you want to delete $itemType no. $label?',
            style: TextStyle(color: palette.text, fontSize: 14),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Cancel',
                style: TextStyle(
                    color: palette.muted, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: palette.danger,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      controller.deleteItem(index);
    }
  }

  Future<void> _editNumber(BuildContext context, int index) async {
    final item = controller.items[index];
    final textController = TextEditingController(text: item.qNum);
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>() ?? QpicPalette.dark;

    final result = await showDialog<({String qNum, bool isSolution, bool? isHindi})>(
      context: context,
      builder: (BuildContext context) {
        bool localIsSolution = item.isSolution;
        bool? localIsHindi = item.isHindi;

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              backgroundColor: palette.panel,
              title: Text(
                'Edit Item Properties',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: textController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Number',
                      labelStyle: TextStyle(color: palette.mutedAlt),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: palette.brand),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: palette.border),
                      ),
                    ),
                    style: TextStyle(color: palette.text),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Type',
                    style: TextStyle(
                      color: palette.mutedAlt,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('Question'),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('Solution'),
                      ),
                    ],
                    selected: {localIsSolution},
                    onSelectionChanged: (Set<bool> val) {
                      setState(() {
                        localIsSolution = val.first;
                      });
                    },
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: palette.brand,
                      selectedForegroundColor: Colors.white,
                      backgroundColor: palette.panelAlt,
                      foregroundColor: palette.text,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  if (bilingualModeActive) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Language / Column',
                      style: TextStyle(
                        color: palette.mutedAlt,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SegmentedButton<bool?>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<bool?>(
                          value: false,
                          label: Text('English'),
                        ),
                        ButtonSegment<bool?>(
                          value: true,
                          label: Text('Hindi'),
                        ),
                        ButtonSegment<bool?>(
                          value: null,
                          label: Text('Auto'),
                        ),
                      ],
                      selected: {localIsHindi},
                      onSelectionChanged: (Set<bool?> val) {
                        setState(() {
                          localIsHindi = val.first;
                        });
                      },
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: palette.brand,
                        selectedForegroundColor: Colors.white,
                        backgroundColor: palette.panelAlt,
                        foregroundColor: palette.text,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: palette.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    final trimmed = textController.text.trim();
                    if (trimmed.isNotEmpty) {
                      Navigator.of(context).pop((
                        qNum: trimmed,
                        isSolution: localIsSolution,
                        isHindi: localIsHindi,
                      ));
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.brand,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      controller.setItemProperties(
        index,
        qNum: result.qNum,
        isSolution: result.isSolution,
        isHindi: result.isHindi,
      );
    }
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
    this.selected = false,
    required this.onToggleSelection,
    required this.prefix,
    required this.onPreview,
    required this.onEditQNum,
    required this.onReselect,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDeletePart,
  });

  final QpicPalette palette;
  final AnalyzedItem item;
  final int index;
  final bool editing;
  final bool selected;
  final VoidCallback onToggleSelection;
  final String prefix;
  final VoidCallback onPreview;
  final VoidCallback onEditQNum;
  final VoidCallback onReselect;
  final VoidCallback onDelete;
  final ValueChanged<int> onMoveUp;
  final ValueChanged<int> onMoveDown;
  final ValueChanged<int> onDeletePart;

  @override
  Widget build(BuildContext context) {
    final String kind = item.isSolution ? 'Solution' : 'Question';
    final bool multi = item.segments.length > 1;
    final bool manual = item.source == 'manual';

    // Border color encodes state, matching the web CSS precedence:
    // editing → brand ring; selected → brandBlue; flagged → warn; manual → brand; else soft border.
    final Color borderColor = editing
        ? palette.brand
        : selected
            ? palette.brandBlue
            : item.flagged
                ? Color.alphaBlend(
                    palette.warn.withValues(alpha: 0.45), palette.border)
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
        border: Border.all(
            color: borderColor, width: (editing || selected) ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  key: ValueKey<String>('review-item-checkbox-$index'),
                  value: selected,
                  activeColor: palette.brandBlue,
                  onChanged: editing
                      ? null
                      : (bool? val) {
                          onToggleSelection();
                        },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '$prefix${item.qNum}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: palette.text,
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            key: ValueKey<String>('review-item-edit-qnum-$index'),
                            onTap: onEditQNum,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Icons.edit_rounded,
                                size: 13,
                                color: palette.brand.withValues(alpha: 0.8),
                              ),
                            ),
                          ),
                        ],
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
              onDeletePart: onDeletePart,
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
    final List<int> pages = item.segments
        .map((QuestionSegment s) => s.page)
        .toSet()
        .toList()
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
    required this.onDeletePart,
  });

  final QpicPalette palette;
  final AnalyzedItem item;
  final String prefix;
  final ValueChanged<int> onMoveUp;
  final ValueChanged<int> onMoveDown;
  final ValueChanged<int> onDeletePart;

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
                  const SizedBox(width: 4),
                  _PartMoveButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Remove part',
                    palette: palette,
                    onPressed: () => onDeletePart(s),
                    danger: true,
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
            child:
                Icon(Icons.visibility_outlined, size: 14, color: palette.brand),
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
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final QpicPalette palette;
  final VoidCallback? onPressed;
  final bool danger;

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
                border: Border.all(
                    color: danger
                        ? palette.danger.withAlpha(128)
                        : palette.border),
              ),
              child: Icon(icon,
                  size: 13, color: danger ? palette.danger : palette.text),
            ),
          ),
        ),
      ),
    );
  }
}
