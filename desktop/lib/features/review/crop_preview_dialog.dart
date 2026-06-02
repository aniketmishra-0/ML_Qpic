// Per-item crop preview popup (the review "Preview" action).
//
// [CropPreviewDialog] shows EXACTLY how a single reviewed question/solution
// will look once cropped, by asking the engine to render that one item through
// the same crop/stitch pipeline the finalized download runs
// (`POST /api/crop/preview` → `crop_and_stitch_hires`). It is a faithful
// "what you see is what you get" preview, not a client-side approximation.
//
// It also carries an "Align parts" toggle for multi-part (stitched) items: the
// user can straighten a column-split question (or turn alignment off) and see
// the result live. The choice is committed onto the item via the controller
// ([ReviewController.setItemAlign]) and rides along into the finalize payload,
// so pressing Finalize downloads precisely the previewed crop.
//
// Engine boundary: ZERO engine logic here. The bytes are rendered by the
// engine; this widget only requests them through the controller and displays
// them.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import '../../models/crop.dart';
import 'review_controller.dart';

/// A modal dialog that previews one reviewed item as a rendered crop image,
/// with a live "Align parts" toggle for stitched multi-part items.
class CropPreviewDialog extends StatefulWidget {
  const CropPreviewDialog({
    super.key,
    required this.controller,
    required this.itemIndex,
    this.questionPrefix = 'Q',
    this.solutionPrefix = 'S',
  });

  /// The shared review session that renders the preview and owns the alignment
  /// override for the item.
  final ReviewController controller;

  /// Index into [ReviewController.items] of the item to preview.
  final int itemIndex;

  /// Box-label prefixes carried from the active tool's output config.
  final String questionPrefix;
  final String solutionPrefix;

  /// Opens the dialog for [itemIndex]. A convenience wrapper around
  /// [showDialog].
  static Future<void> open(
    BuildContext context, {
    required ReviewController controller,
    required int itemIndex,
    String questionPrefix = 'Q',
    String solutionPrefix = 'S',
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => CropPreviewDialog(
        controller: controller,
        itemIndex: itemIndex,
        questionPrefix: questionPrefix,
        solutionPrefix: solutionPrefix,
      ),
    );
  }

  @override
  State<CropPreviewDialog> createState() => _CropPreviewDialogState();
}

class _CropPreviewDialogState extends State<CropPreviewDialog> {
  Uint8List? _bytes;
  bool _loading = true;
  String? _error;

  /// Local alignment choice driving the live preview. Seeded from the item's
  /// committed override and applied to the item when the user confirms.
  bool? _align;

  /// Manual-align mode: when on, per-part nudge controls are shown and the user
  /// can shift each stitched part left/right. Off by default so the popup stays
  /// the simple on/off toggle unless the user opts into fine control.
  bool _manualMode = false;

  /// Debounce so dragging a nudge slider doesn't fire a render per pixel.
  Timer? _renderDebounce;

  @override
  void initState() {
    super.initState();
    _align = widget.controller.alignFor(widget.itemIndex);
    // If the item already carries manual nudges (re-opening the popup), start
    // in manual mode so the user sees and keeps their adjustments.
    _manualMode =
        widget.controller.offsetsFor(widget.itemIndex).any((double o) => o != 0.0);
    _render();
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    super.dispose();
  }

  Future<void> _render() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.controller.previewItem(
        widget.itemIndex,
        alignOverride: _align,
      );
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Could not render this preview.';
        });
        return;
      }
      setState(() {
        _bytes = Uint8List.fromList(bytes);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not render this preview.';
      });
    }
  }

  /// Re-renders after a short pause so a flurry of nudges collapses into one
  /// request (the engine round-trips a full crop each time).
  void _renderDebounced() {
    _renderDebounce?.cancel();
    _renderDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) _render();
    });
  }

  void _setAlign(bool value) {
    if (_align == value) return;
    setState(() => _align = value);
    // Commit the choice so Finalize downloads exactly what's previewed, then
    // re-render to reflect it.
    widget.controller.setItemAlign(widget.itemIndex, value);
    _render();
  }

  void _toggleManualMode(bool value) {
    setState(() => _manualMode = value);
  }

  /// Nudges part [segmentIndex] to [xOffsetPct] (% of page width) and re-renders
  /// (debounced). The choice is committed onto the item so Finalize matches.
  void _setOffset(int segmentIndex, double xOffsetPct) {
    widget.controller.setSegmentOffset(
      widget.itemIndex,
      segmentIndex,
      xOffsetPct,
    );
    setState(() {});
    _renderDebounced();
  }

  void _resetOffsets() {
    widget.controller.resetSegmentOffsets(widget.itemIndex);
    setState(() {});
    _render();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final size = MediaQuery.of(context).size;

    final Color panel = palette?.panel ?? theme.colorScheme.surface;
    final Color border = palette?.border ?? theme.dividerColor;
    final Color text = palette?.text ?? theme.colorScheme.onSurface;
    final Color muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final Color brand = palette?.brand ?? theme.colorScheme.primary;

    final List<AnalyzedItem> items = widget.controller.items;
    final AnalyzedItem? item =
        (widget.itemIndex >= 0 && widget.itemIndex < items.length)
            ? items[widget.itemIndex]
            : null;
    final bool isSolution = item?.isSolution ?? false;
    final String prefix =
        isSolution ? widget.solutionPrefix : widget.questionPrefix;
    final String label = item != null ? '$prefix${item.qNum}' : 'Preview';
    final int partCount = item?.segments.length ?? 0;
    final bool multiPart = partCount > 1;
    final List<double> offsets = widget.controller.offsetsFor(widget.itemIndex);

    return Dialog(
      key: const ValueKey<String>('crop-preview-dialog'),
      backgroundColor: panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(28),
      child: SizedBox(
        width: size.width * 0.6,
        height: size.height * 0.82,
        child: Column(
          children: <Widget>[
            _Header(
              label: label,
              kind: isSolution ? 'Solution' : 'Question',
              text: text,
              muted: muted,
              brand: brand,
              border: border,
            ),
            if (multiPart)
              _AlignBar(
                key: const ValueKey<String>('crop-preview-align-bar'),
                align: _align,
                onChanged: _setAlign,
                manualMode: _manualMode,
                onManualModeChanged: _toggleManualMode,
                text: text,
                muted: muted,
                brand: brand,
                border: border,
              ),
            if (multiPart && _manualMode)
              _ManualAlignBar(
                key: const ValueKey<String>('crop-preview-manual-bar'),
                offsets: offsets,
                onChanged: _setOffset,
                onReset: _resetOffsets,
                text: text,
                muted: muted,
                brand: brand,
                border: border,
              ),
            Expanded(
              child: _Body(
                loading: _loading,
                error: _error,
                bytes: _bytes,
                muted: muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.label,
    required this.kind,
    required this.text,
    required this.muted,
    required this.brand,
    required this.border,
  });

  final String label;
  final String kind;
  final Color text;
  final Color muted;
  final Color brand;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.crop_rounded, color: brand, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Crop preview · $label',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'This is exactly how $kind $label will be cropped.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('crop-preview-close'),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close_rounded),
            color: muted,
          ),
        ],
      ),
    );
  }
}

/// The "Align parts" control for multi-part items. Aligning left-aligns the
/// stitched column-split parts so the question reads cleanly; the choice is
/// committed to the item and used by the finalized download too. A secondary
/// "Manual" toggle reveals the per-part nudge controls ([_ManualAlignBar]) for
/// fine adjustments on top of the automatic alignment.
class _AlignBar extends StatelessWidget {
  const _AlignBar({
    super.key,
    required this.align,
    required this.onChanged,
    required this.manualMode,
    required this.onManualModeChanged,
    required this.text,
    required this.muted,
    required this.brand,
    required this.border,
  });

  /// Null = engine default (align manual items only); true/false = forced.
  final bool? align;
  final ValueChanged<bool> onChanged;
  final bool manualMode;
  final ValueChanged<bool> onManualModeChanged;
  final Color text;
  final Color muted;
  final Color brand;
  final Color border;

  @override
  Widget build(BuildContext context) {
    // A null override means "engine default"; for multi-part items the default
    // is to align manual items. Present the toggle as on unless explicitly off.
    final bool on = align ?? true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.format_align_left_rounded, size: 18, color: muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Align parts — line up the stitched pieces so the question is '
              'straight.',
              style: TextStyle(fontSize: 12.5, color: text),
            ),
          ),
          const SizedBox(width: 12),
          // Reveal the per-part nudge controls for hands-on adjustments.
          TextButton.icon(
            key: const ValueKey<String>('crop-preview-manual-toggle'),
            onPressed: () => onManualModeChanged(!manualMode),
            icon: Icon(
              manualMode ? Icons.tune_rounded : Icons.tune_outlined,
              size: 16,
              color: manualMode ? brand : muted,
            ),
            label: Text(
              'Manual',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: manualMode ? brand : muted,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            key: const ValueKey<String>('crop-preview-align-switch'),
            value: on,
            activeThumbColor: brand,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Per-part manual alignment controls (the "Manual align" mode). Each stitched
/// part gets a slider that nudges it left/right (as a signed % of page width),
/// applied on top of the automatic alignment. The nudge rides into the
/// preview and the finalize payload, so "Done"/Finalize reproduce the exact
/// alignment shown here.
class _ManualAlignBar extends StatelessWidget {
  const _ManualAlignBar({
    super.key,
    required this.offsets,
    required this.onChanged,
    required this.onReset,
    required this.text,
    required this.muted,
    required this.brand,
    required this.border,
  });

  /// Current nudge per part (% of page width), in segment order.
  final List<double> offsets;

  /// Called with (segmentIndex, newOffsetPct) as the user drags a slider.
  final void Function(int segmentIndex, double xOffsetPct) onChanged;
  final VoidCallback onReset;
  final Color text;
  final Color muted;
  final Color brand;
  final Color border;

  /// Largest nudge in either direction, as a % of page width. A part can be
  /// pushed up to a quarter of the page; plenty for column-split fine-tuning.
  static const double _range = 25.0;

  @override
  Widget build(BuildContext context) {
    final bool anyNudge = offsets.any((double o) => o.abs() > 1e-6);
    return Container(
      key: const ValueKey<String>('crop-preview-manual-controls'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.04),
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Manual align — drag a part left or right to line it up.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey<String>('crop-preview-manual-reset'),
                onPressed: anyNudge ? onReset : null,
                child: Text(
                  'Reset',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: anyNudge ? brand : muted.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ),
          for (int i = 0; i < offsets.length; i++)
            Row(
              key: ValueKey<String>('crop-preview-part-$i'),
              children: <Widget>[
                SizedBox(
                  width: 56,
                  child: Text(
                    'Part ${i + 1}',
                    style: TextStyle(fontSize: 12, color: text),
                  ),
                ),
                Expanded(
                  child: Slider(
                    key: ValueKey<String>('crop-preview-part-slider-$i'),
                    min: -_range,
                    max: _range,
                    value: offsets[i].clamp(-_range, _range),
                    activeColor: brand,
                    onChanged: (double v) => onChanged(i, v),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${offsets[i] >= 0 ? '+' : ''}'
                    '${offsets[i].toStringAsFixed(0)}%',
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.loading,
    required this.error,
    required this.bytes,
    required this.muted,
  });

  final bool loading;
  final String? error;
  final Uint8List? bytes;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
        ),
      );
    }
    final data = bytes;
    if (data == null) {
      return Center(
        child: Text('Nothing to preview.', style: TextStyle(color: muted)),
      );
    }
    return Container(
      color: Colors.black.withValues(alpha: 0.15),
      child: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(
                data,
                key: const ValueKey<String>('crop-preview-image'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
