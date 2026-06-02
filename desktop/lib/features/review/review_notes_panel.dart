// Review Notes Panel (`review_notes_panel.dart`) — Req 10.
//
// The right-hand advisory list of the Review Canvas. It renders the engine's
// review notes verbatim and wires the one-click "Fix" affordance, faithfully
// reproducing the web UI's `renderNotes()` (`static/index.html`):
//
//   * Each [ReviewNote] is shown with its `kind` + `message` (10.1).
//   * An empty notes list shows the "Detection looks complete…" advisory (10.2)
//     — styled exactly like the web's `.note.gap` reassurance row.
//   * The five kinds (`duplicate`, `gap`, `tiny`, `incomplete`, `low_confidence`)
//     are visually distinguished by per-kind color + icon chips reproducing the
//     web `.note` / `.note.gap` / `.note.incomplete` CSS, with a distinct icon
//     for each kind so all five read apart at a glance (10.5).
//   * A note with `kind == "incomplete"` and a non-null `q_num` gets a **Fix**
//     button (10.3) that, when activated, navigates to the referenced item's
//     page and enters additive re-select on it (10.4) via the
//     [ReviewController] — exactly what the web "Fix" button does through
//     `startEditing`.
//
// Engine boundary (Req 1.5): ZERO engine logic here. This widget only reads the
// notes the engine already returned (the controller's [ReviewController.notes])
// and drives re-select through the controller; it computes no detection, crop,
// or geometry. The Fix action delegates to
// [ReviewController.startReselectForNote], which locates the item by `q_num` +
// type and calls the canvas controller's `startEditing` (page jump + re-select).
//
// Colors come from [QpicPalette] (the web CSS variables): `noteGap` (`--accent`)
// for gap notes, `noteIncomplete` (`--danger`) for incomplete notes, and
// `noteDefault` (`--warn`) for the rest — matching the web rule set. Backgrounds
// and borders blend the accent over the panel/border tokens to mirror the web's
// `color-mix(... N%, var(--panel-2))` / `color-mix(... N%, var(--border))`.

import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import '../../models/crop.dart';
import 'review_controller.dart';

/// The advisory message shown when the engine returns no review notes (10.2).
/// Copied verbatim from the web `renderNotes()` reassurance row.
const String kDetectionCompleteAdvisory =
    'Detection looks complete. Review below and add anything that was missed, '
    'then download.';

/// Renders the engine's [ReviewNote]s and their Fix actions (Req 10).
///
/// Binds to a [ReviewController] so the list re-renders whenever a note is
/// resolved (re-selecting an item clears its matching note) or a new session is
/// loaded. Holds no state of its own.
class ReviewNotesPanel extends StatelessWidget {
  const ReviewNotesPanel({super.key, required this.controller});

  /// The session controller exposing [ReviewController.notes] and the Fix
  /// action's re-select entry point [ReviewController.startReselectForNote].
  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    final QpicPalette palette =
        Theme.of(context).extension<QpicPalette>() ?? QpicPalette.dark;

    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<ReviewNote> notes = controller.notes;

        // Empty → the "detection looks complete" advisory (10.2).
        if (notes.isEmpty) {
          return Column(
            key: const ValueKey<String>('review-notes-panel'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _NoteRow(
                key: const ValueKey<String>('review-notes-advisory'),
                palette: palette,
                kind: 'gap',
                message: kDetectionCompleteAdvisory,
              ),
            ],
          );
        }

        // Non-empty → an "Items to Fix" header with a count badge, then one row
        // per note (web `notes-head` + `.note` rows).
        return Column(
          key: const ValueKey<String>('review-notes-panel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _NotesHeader(palette: palette, count: notes.length),
            const SizedBox(height: 8),
            for (int i = 0; i < notes.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                child: _NoteRow(
                  key: ValueKey<String>('review-note-$i'),
                  palette: palette,
                  kind: notes[i].kind,
                  message: notes[i].message,
                  // Fix only for incomplete notes carrying a question number
                  // (10.3). Tapping it navigates + re-selects (10.4).
                  onFix: _canFix(notes[i])
                      ? () => controller.startReselectForNote(notes[i])
                      : null,
                  fixKey: ValueKey<String>(
                    'review-note-fix-${notes[i].qNum}',
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// A note shows a Fix action iff it is an `incomplete` cut-off note that names
  /// a question number (Req 10.3) — identical to the web guard
  /// `nt.kind === 'incomplete' && nt.q_num != null`.
  static bool _canFix(ReviewNote note) =>
      note.kind == 'incomplete' && note.qNum != null;
}

/// The "Items to Fix" summary header above the notes list (web `.notes-head`).
class _NotesHeader extends StatelessWidget {
  const _NotesHeader({required this.palette, required this.count});

  final QpicPalette palette;
  final int count;

  @override
  Widget build(BuildContext context) {
    final Color accent = palette.danger;
    return Container(
      key: const ValueKey<String>('review-notes-head'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color:
            Color.alphaBlend(accent.withValues(alpha: 0.10), palette.panelAlt),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: Color.alphaBlend(
              accent.withValues(alpha: 0.40), palette.border),
        ),
      ),
      child: Row(
        children: <Widget>[
          Text(
            'Items to Fix',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: palette.text,
            ),
          ),
          const Spacer(),
          Container(
            key: const ValueKey<String>('review-notes-count'),
            constraints: const BoxConstraints(minWidth: 22),
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent,
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

/// A single advisory row reproducing the web `.note` chip: a per-kind colored
/// icon + the message, with an optional trailing Fix button.
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    super.key,
    required this.palette,
    required this.kind,
    required this.message,
    this.onFix,
    this.fixKey,
  });

  final QpicPalette palette;
  final String kind;
  final String message;
  final VoidCallback? onFix;
  final Key? fixKey;

  @override
  Widget build(BuildContext context) {
    final Color accent = _accentForKind(palette, kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        // web: background: color-mix(in srgb, var(--accent) 9%, var(--panel-2))
        color:
            Color.alphaBlend(accent.withValues(alpha: 0.09), palette.panelAlt),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          // web: border: color-mix(in srgb, var(--accent) 35-40%, var(--border))
          color: Color.alphaBlend(
            accent.withValues(alpha: kind == 'incomplete' ? 0.40 : 0.35),
            palette.border,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Per-kind icon chip (color distinguishes gap/incomplete/default like
          // the web `.note-dot`; the icon shape distinguishes all five — 10.5).
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_iconForKind(kind), size: 16, color: accent),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: palette.text),
            ),
          ),
          if (onFix != null) ...<Widget>[
            const SizedBox(width: 9),
            _FixButton(key: fixKey, palette: palette, onPressed: onFix!),
          ],
        ],
      ),
    );
  }

  /// Maps a note kind to its accent color, matching the web CSS:
  ///   * `gap` → `--accent` (brand),
  ///   * `incomplete` → `--danger`,
  ///   * `duplicate` / `tiny` / `low_confidence` (default) → `--warn`.
  static Color _accentForKind(QpicPalette palette, String kind) {
    switch (kind) {
      case 'gap':
        return palette.noteGap;
      case 'incomplete':
        return palette.noteIncomplete;
      case 'duplicate':
      case 'tiny':
      case 'low_confidence':
      default:
        return palette.noteDefault;
    }
  }

  /// A distinct icon per kind so all five are visually separable (10.5). The
  /// web uses a single colored dot; we keep the color mapping and add a shape.
  static IconData _iconForKind(String kind) {
    switch (kind) {
      case 'duplicate':
        return Icons.content_copy_outlined;
      case 'gap':
        return Icons.unfold_more;
      case 'tiny':
        return Icons.photo_size_select_small_outlined;
      case 'incomplete':
        return Icons.warning_amber_rounded;
      case 'low_confidence':
        return Icons.help_outline;
      default:
        return Icons.info_outline;
    }
  }
}

/// The brand-filled "Fix" button (web `.note-fix`).
class _FixButton extends StatelessWidget {
  const _FixButton({
    super.key,
    required this.palette,
    required this.onPressed,
  });

  final QpicPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.brand,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(
            'Fix',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
