import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/file_picker_service.dart';

/// Signature for the callback invoked when one or more accepted files are
/// dropped onto a [DropFileTarget].
typedef DropAcceptedCallback = void Function(List<XFile> files);

/// Signature for the callback invoked when a drop is rejected because none of
/// the dropped files matched the target's accepted extensions.
///
/// The [message] is a human-readable explanation (for example, `"PDF required"`)
/// that feature code can surface via a `SnackBar` or inline status line.
typedef DropRejectedCallback = void Function(String message);

/// Signature for building the visual wrapper around the drop target's child.
///
/// [isDragOver] is `true` while a drag is hovering over the target, allowing
/// callers to render their own acceptance indicator. Implementations should
/// return a widget that wraps [child].
typedef DropOverlayBuilder = Widget Function(
  BuildContext context,
  bool isDragOver,
  Widget child,
);

/// A reusable drag-and-drop file target for the Qpic desktop tool zones
/// (Requirement 18).
///
/// This widget wraps `desktop_drop`'s [DropTarget] and adds the engine-agnostic
/// behaviour the design calls for:
///
/// * Dropping a file whose extension is in [acceptedExtensions] invokes
///   [onAccepted] with the matching file(s) so feature code can load them into
///   the active tool (18.1).
/// * While a drag hovers over the target, an acceptance visual is shown (18.2).
///   The default overlay highlights the target with the theme's primary colour;
///   callers may supply their own [overlayBuilder].
/// * Dropping only unsupported files (for example, a non-PDF onto a PDF-only
///   target) rejects the drop and reports [rejectionMessage] through
///   [onRejected] (18.3).
///
/// Two ready-made modes mirror the file-open dialogs in [FilePickerService]:
///
/// * [DropFileTarget.pdfOnly] for the crop and tools zones.
/// * [DropFileTarget.imagesAndPdf] for the Rename Batch zone, which also
///   accepts images.
///
/// The widget contains no engine logic; it only resolves the dropped selection
/// and hands raw [XFile]s to its callbacks.
class DropFileTarget extends StatefulWidget {
  /// Creates a drop target accepting files with the given [acceptedExtensions].
  ///
  /// Extensions are matched case-insensitively and must be given without a
  /// leading dot (for example, `'pdf'`, not `'.pdf'`).
  const DropFileTarget({
    super.key,
    required this.acceptedExtensions,
    required this.onAccepted,
    required this.child,
    this.onRejected,
    this.rejectionMessage = 'PDF required',
    this.enabled = true,
    this.allowMultiple = true,
    this.overlayBuilder,
  });

  /// Creates a PDF-only drop target for the crop and tools zones.
  ///
  /// Dropping anything other than a PDF rejects the drop with a
  /// "PDF required" message (18.3).
  factory DropFileTarget.pdfOnly({
    Key? key,
    required DropAcceptedCallback onAccepted,
    required Widget child,
    DropRejectedCallback? onRejected,
    String rejectionMessage = 'PDF required',
    bool enabled = true,
    DropOverlayBuilder? overlayBuilder,
  }) {
    return DropFileTarget(
      key: key,
      acceptedExtensions: pdfExtensions,
      onAccepted: onAccepted,
      onRejected: onRejected,
      rejectionMessage: rejectionMessage,
      enabled: enabled,
      // Crop/Tools flows operate on a single source PDF.
      allowMultiple: false,
      overlayBuilder: overlayBuilder,
      child: child,
    );
  }

  /// Creates a drop target for the Rename Batch zone, accepting images and PDFs.
  ///
  /// Dropping a file that is neither an image nor a PDF rejects the drop with
  /// [rejectionMessage].
  factory DropFileTarget.imagesAndPdf({
    Key? key,
    required DropAcceptedCallback onAccepted,
    required Widget child,
    DropRejectedCallback? onRejected,
    String rejectionMessage = 'Drop images or a PDF',
    bool enabled = true,
    DropOverlayBuilder? overlayBuilder,
  }) {
    return DropFileTarget(
      key: key,
      acceptedExtensions: imagesAndPdfExtensions,
      onAccepted: onAccepted,
      onRejected: onRejected,
      rejectionMessage: rejectionMessage,
      enabled: enabled,
      // Rename Batch ingests a batch of inputs at once.
      allowMultiple: true,
      overlayBuilder: overlayBuilder,
      child: child,
    );
  }

  /// Extensions accepted by the PDF-only mode.
  static const List<String> pdfExtensions = <String>['pdf'];

  /// Extensions accepted by the images-and-PDF (Rename Batch) mode.
  ///
  /// Reuses [FilePickerService.imageExtensions] so the drop target and the
  /// native open dialog stay in lockstep, then appends `pdf`.
  static const List<String> imagesAndPdfExtensions = <String>[
    ...FilePickerService.imageExtensions,
    'pdf',
  ];

  /// File extensions (lowercase, no leading dot) this target accepts.
  final List<String> acceptedExtensions;

  /// Invoked with the accepted files when a drop contains at least one match.
  final DropAcceptedCallback onAccepted;

  /// Invoked with [rejectionMessage] when a drop contains no accepted files.
  final DropRejectedCallback? onRejected;

  /// The child rendered inside the drop zone (the tool's normal content).
  final Widget child;

  /// Message reported through [onRejected] when a drop is rejected.
  final String rejectionMessage;

  /// Whether the target currently accepts drops. When `false`, drops are
  /// ignored (used to gate input until the engine is ready).
  final bool enabled;

  /// Whether to forward every accepted file ([allowMultiple] = `true`) or only
  /// the first one. PDF-only flows take a single source file.
  final bool allowMultiple;

  /// Optional custom builder for the hover/acceptance visual. When omitted, a
  /// default highlight overlay is used.
  final DropOverlayBuilder? overlayBuilder;

  @override
  State<DropFileTarget> createState() => _DropFileTargetState();

  /// Returns the lowercase extension of [nameOrPath] without its leading dot,
  /// or an empty string when there is no extension.
  @visibleForTesting
  static String normalizedExtension(String nameOrPath) {
    final String ext = p.extension(nameOrPath);
    if (ext.isEmpty) return '';
    return ext.substring(1).toLowerCase();
  }

  /// Whether [nameOrPath]'s extension is contained in [acceptedExtensions]
  /// (case-insensitive). Files without an extension are never accepted.
  @visibleForTesting
  static bool isAccepted(String nameOrPath, List<String> acceptedExtensions) {
    final String ext = normalizedExtension(nameOrPath);
    if (ext.isEmpty) return false;
    for (final String accepted in acceptedExtensions) {
      if (accepted.toLowerCase() == ext) return true;
    }
    return false;
  }
}

class _DropFileTargetState extends State<DropFileTarget> {
  bool _isDragOver = false;

  void _setDragOver(bool value) {
    if (_isDragOver == value) return;
    setState(() => _isDragOver = value);
  }

  void _handleDragDone(DropDoneDetails detail) {
    _setDragOver(false);
    if (!widget.enabled) return;

    final List<XFile> dropped = detail.files;
    if (dropped.isEmpty) return;

    final List<XFile> accepted = <XFile>[];
    for (final XFile file in dropped) {
      final String identifier = file.name.isNotEmpty ? file.name : file.path;
      if (DropFileTarget.isAccepted(identifier, widget.acceptedExtensions)) {
        accepted.add(file);
      }
    }

    if (accepted.isNotEmpty) {
      final List<XFile> delivered =
          widget.allowMultiple ? accepted : accepted.sublist(0, 1);
      widget.onAccepted(delivered);
      return;
    }

    // Nothing acceptable was dropped (for example, an image on a PDF-only
    // target): reject and inform the user (18.3).
    widget.onRejected?.call(widget.rejectionMessage);
  }

  Widget _defaultOverlay(BuildContext context, bool isDragOver, Widget child) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = scheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      // `foregroundDecoration` paints over the child without affecting layout,
      // so the highlight never shifts the tool content while dragging.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDragOver ? accent : Colors.transparent,
          width: 2,
        ),
        color: isDragOver ? accent.withAlpha(20) : Colors.transparent,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final DropOverlayBuilder builder = widget.overlayBuilder ?? _defaultOverlay;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setDragOver(true),
      onDragExited: (_) => _setDragOver(false),
      onDragDone: _handleDragDone,
      child: builder(context, _isDragOver, widget.child),
    );
  }
}
