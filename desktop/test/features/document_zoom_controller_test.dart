import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/canvas_geometry.dart'
    show kFitWidthZoom, kZoomMax, kZoomMin;
import 'package:qpic_desktop/features/shell/document_zoom_controller.dart';

void main() {
  group('DocumentZoomController', () {
    test('starts at fit-width (1.0) by default', () {
      final controller = DocumentZoomController();
      expect(controller.zoom, equals(kFitWidthZoom));
      controller.dispose();
    });

    test('clamps an out-of-range starting zoom into [0.25, 6.0]', () {
      final low = DocumentZoomController(zoom: 0.01);
      final high = DocumentZoomController(zoom: 99.0);
      expect(low.zoom, equals(kZoomMin));
      expect(high.zoom, equals(kZoomMax));
      low.dispose();
      high.dispose();
    });

    test('zoomIn increases zoom by the step', () {
      final controller = DocumentZoomController(zoom: 1.0, step: 0.1);
      controller.zoomIn();
      expect(controller.zoom, closeTo(1.1, 1e-9));
      controller.dispose();
    });

    test('zoomOut decreases zoom by the step', () {
      final controller = DocumentZoomController(zoom: 1.0, step: 0.1);
      controller.zoomOut();
      expect(controller.zoom, closeTo(0.9, 1e-9));
      controller.dispose();
    });

    test('reset returns to fit-width (1.0)', () {
      final controller = DocumentZoomController(zoom: 2.5);
      controller.reset();
      expect(controller.zoom, equals(kFitWidthZoom));
      controller.dispose();
    });

    test('zoomIn never exceeds the maximum (6.0)', () {
      final controller = DocumentZoomController(zoom: kZoomMax, step: 0.5);
      controller.zoomIn();
      expect(controller.zoom, equals(kZoomMax));
      controller.dispose();
    });

    test('zoomOut never drops below the minimum (0.25)', () {
      final controller = DocumentZoomController(zoom: kZoomMin, step: 0.5);
      controller.zoomOut();
      expect(controller.zoom, equals(kZoomMin));
      controller.dispose();
    });

    test('setZoom clamps the requested value', () {
      final controller = DocumentZoomController();
      controller.setZoom(100.0);
      expect(controller.zoom, equals(kZoomMax));
      controller.setZoom(-5.0);
      expect(controller.zoom, equals(kZoomMin));
      controller.dispose();
    });

    test('canZoomIn / canZoomOut reflect the bounds', () {
      final atMax = DocumentZoomController(zoom: kZoomMax);
      expect(atMax.canZoomIn, isFalse);
      expect(atMax.canZoomOut, isTrue);

      final atMin = DocumentZoomController(zoom: kZoomMin);
      expect(atMin.canZoomIn, isTrue);
      expect(atMin.canZoomOut, isFalse);

      atMax.dispose();
      atMin.dispose();
    });

    test('notifies listeners only when the zoom actually changes', () {
      final controller = DocumentZoomController(zoom: kZoomMax, step: 0.5);
      var notifications = 0;
      controller.addListener(() => notifications++);

      // Already at the cap: a further zoomIn changes nothing → no notify.
      controller.zoomIn();
      expect(notifications, equals(0));

      // A real change notifies once.
      controller.zoomOut();
      expect(notifications, equals(1));

      controller.dispose();
    });

    test('rejects a non-positive step', () {
      expect(
        () => DocumentZoomController(step: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
