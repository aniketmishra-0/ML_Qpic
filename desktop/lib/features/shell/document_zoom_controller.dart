// Zoom state for the "active document view" driven by the menu bar and the
// Ctrl/Cmd +/-/0 shortcuts (Requirement 19.4).
//
// The desktop shells expose familiar browser-style zoom: `desktop_qt.py` wires
// Ctrl/Cmd +, -, and 0 to zoom-in / zoom-out / reset on the active web view.
// This file reproduces that behaviour for the Flutter client, but the zoom it
// drives is the *document view's* zoom — primarily the Review Canvas, whose
// own zoom contract is clamped to 0.25..6.0 with fit-width == 1.0 (Req 8.9).
//
// To keep a single source of truth for those bounds, the clamping and the
// fit-width baseline are reused verbatim from `canvas_geometry.dart` rather
// than redefined here.

import 'package:flutter/foundation.dart';

import '../review/canvas_geometry.dart'
    show clampZoom, kFitWidthZoom, kZoomMax, kZoomMin;

/// Default increment applied per zoom-in / zoom-out step.
///
/// Matches `desktop_qt.py`'s `zoomFactor() ± 0.1` step so the keyboard feel is
/// the same as the retired Qt shell.
const double kZoomStep = 0.1;

/// Holds the zoom factor for a single document view and notifies listeners when
/// it changes.
///
/// A document view (e.g. the Review Canvas) owns one of these and binds its
/// rendered zoom to [zoom]. The view registers itself as the
/// [ActiveDocumentZoom] while it is on screen, so the shell's menu items and
/// zoom shortcuts drive whichever view is currently active.
///
/// The factor is always kept inside [kZoomMin]..[kZoomMax] via [clampZoom], so
/// a controller can never report or apply an out-of-range zoom (Req 8.9, 19.4).
class DocumentZoomController extends ChangeNotifier {
  /// Creates a controller starting at [zoom] (clamped) with the given per-step
  /// [step] increment.
  DocumentZoomController({double zoom = kFitWidthZoom, this.step = kZoomStep})
      : assert(step > 0, 'step must be positive'),
        _zoom = clampZoom(zoom);

  /// Amount added/removed by [zoomIn] / [zoomOut].
  final double step;

  double _zoom;

  /// The current zoom factor, always within [kZoomMin]..[kZoomMax].
  double get zoom => _zoom;

  /// Whether a further [zoomIn] would change anything (not already at the cap).
  bool get canZoomIn => _zoom < kZoomMax;

  /// Whether a further [zoomOut] would change anything (not already at the floor).
  bool get canZoomOut => _zoom > kZoomMin;

  /// Increase zoom by [step] (Ctrl/Cmd +). Clamped at [kZoomMax].
  void zoomIn() => _apply(_zoom + step);

  /// Decrease zoom by [step] (Ctrl/Cmd -). Clamped at [kZoomMin].
  void zoomOut() => _apply(_zoom - step);

  /// Reset to fit-width (Ctrl/Cmd 0), i.e. zoom == [kFitWidthZoom] (100%).
  void reset() => _apply(kFitWidthZoom);

  /// Set an explicit zoom factor; the value is clamped before being applied.
  void setZoom(double value) => _apply(value);

  void _apply(double value) {
    final double next = clampZoom(value);
    if (next == _zoom) return;
    _zoom = next;
    notifyListeners();
  }
}

/// Registry of the currently-active [DocumentZoomController].
///
/// The shell owns one of these and exposes it to the widget tree through a
/// [DocumentZoomScope]. The menu bar and the zoom shortcuts call [zoomIn],
/// [zoomOut], and [reset] on it; the registry forwards to whichever controller
/// the active document view has registered. When no document view is active
/// (e.g. the Auto Crop form is showing and there is nothing to zoom), the
/// registry holds `null` and the zoom commands are harmless no-ops.
class ActiveDocumentZoom extends ChangeNotifier {
  DocumentZoomController? _active;

  /// The controller for the document view that is currently on screen, or null.
  DocumentZoomController? get active => _active;

  /// Whether a document view is currently registered (zoom is meaningful).
  bool get hasActive => _active != null;

  /// Make [controller] the active zoom target. Idempotent for the same
  /// controller; replaces any previously-registered controller.
  void register(DocumentZoomController controller) {
    if (identical(_active, controller)) return;
    _active = controller;
    notifyListeners();
  }

  /// Clear [controller] as the active target. No-op if a different controller
  /// is currently active (the newer registration wins).
  void unregister(DocumentZoomController controller) {
    if (!identical(_active, controller)) return;
    _active = null;
    notifyListeners();
  }

  /// Forward a zoom-in to the active controller, if any.
  void zoomIn() => _active?.zoomIn();

  /// Forward a zoom-out to the active controller, if any.
  void zoomOut() => _active?.zoomOut();

  /// Forward a reset-to-fit-width to the active controller, if any.
  void reset() => _active?.reset();
}
