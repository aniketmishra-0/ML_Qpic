// Exposes the shell's [ActiveDocumentZoom] registry to the widget tree so a
// document view can register itself as the zoom target while it is on screen
// (Requirement 19.4).
//
// The shell installs a single [DocumentZoomScope] above the tool views. Each
// document view (the Review Canvas, primarily) looks the registry up with
// [DocumentZoomScope.of] and registers/unregisters its own
// [DocumentZoomController] in `initState`/`dispose`. The menu bar and the
// Ctrl/Cmd +/-/0 shortcuts then drive whichever controller is active.

import 'package:flutter/widgets.dart';

import 'document_zoom_controller.dart';

/// Inherited access to the shell-wide [ActiveDocumentZoom] registry.
class DocumentZoomScope extends InheritedWidget {
  /// Wraps [child], publishing [registry] to descendants.
  const DocumentZoomScope({
    super.key,
    required this.registry,
    required super.child,
  });

  /// The shared registry the active document view registers with.
  final ActiveDocumentZoom registry;

  /// Returns the nearest registry, or null when there is no [DocumentZoomScope]
  /// ancestor (e.g. lightweight tests that don't install the shell).
  static ActiveDocumentZoom? maybeOf(BuildContext context) {
    final DocumentZoomScope? scope =
        context.dependOnInheritedWidgetOfExactType<DocumentZoomScope>();
    return scope?.registry;
  }

  /// Returns the nearest registry. Throws if no [DocumentZoomScope] is found,
  /// so a document view that depends on shell zoom fails loudly when mis-wired.
  static ActiveDocumentZoom of(BuildContext context) {
    final ActiveDocumentZoom? registry = maybeOf(context);
    assert(registry != null, 'No DocumentZoomScope found in context');
    return registry!;
  }

  @override
  bool updateShouldNotify(DocumentZoomScope oldWidget) =>
      registry != oldWidget.registry;
}
