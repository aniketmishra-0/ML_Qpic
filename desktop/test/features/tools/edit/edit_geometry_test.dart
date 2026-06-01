// Unit tests for the Edit tool's bbox→pixel mapping (Req 15.2, 15.3).
//
// These cover the span-overlay geometry: converting a span `bbox` (PDF points)
// to a display-space rectangle over a page rendered at a given size, and the
// fit-width display-size helper. They mirror the web `layoutSpans` math so the
// native overlay lines up with the server-rendered PNG exactly.

import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/features/tools/edit/edit_geometry.dart';
import 'package:qpic_desktop/models/tools.dart';

EditPageModel _page({
  int page = 1,
  double width = 612, // US Letter width in points
  double height = 792, // US Letter height in points
}) {
  return EditPageModel(
    page: page,
    width: width,
    height: height,
    previewUrl: '/api/tools/edit/job/page/$page',
  );
}

void main() {
  group('displaySizeForWidth', () {
    test('fits the page width and preserves aspect ratio', () {
      final size = displaySizeForWidth(_page(width: 600, height: 900), 300);
      expect(size.width, 300);
      // 300 * (900/600) = 450
      expect(size.height, 450);
    });

    test('returns Size.zero for a non-positive available width', () {
      expect(displaySizeForWidth(_page(), 0), Size.zero);
      expect(displaySizeForWidth(_page(), -10), Size.zero);
    });

    test('returns Size.zero for a degenerate page', () {
      expect(displaySizeForWidth(_page(width: 0, height: 0), 300), Size.zero);
    });
  });

  group('spanDisplayRect', () {
    test('scales point coordinates by displaySize / pageSize', () {
      // Page 100x200 pt rendered at 200x400 px → 2x scale on each axis.
      final rect = spanDisplayRect(
        bbox: const <double>[10, 20, 40, 60],
        pageSize: const Size(100, 200),
        displaySize: const Size(200, 400),
      );
      expect(rect.left, 20); // 10 * 2
      expect(rect.top, 40); // 20 * 2
      expect(rect.width, 60); // (40-10) * 2
      expect(rect.height, 80); // (60-20) * 2
    });

    test('is identity when displaySize equals pageSize (1:1)', () {
      // Use a bbox larger than the min box size so the 1:1 mapping is exact
      // and not masked by the min-size clamp (covered separately below).
      final rect = spanDisplayRect(
        bbox: const <double>[5, 6, 45, 56],
        pageSize: const Size(100, 100),
        displaySize: const Size(100, 100),
      );
      expect(rect, const Rect.fromLTWH(5, 6, 40, 50));
    });

    test('clamps width/height to the minimum box size', () {
      // A hair-thin run (zero height) must still be a grabbable target.
      final rect = spanDisplayRect(
        bbox: const <double>[10, 10, 12, 10],
        pageSize: const Size(100, 100),
        displaySize: const Size(100, 100),
        minSize: 6,
      );
      expect(rect.width, 6); // raw 2 < 6 → clamped
      expect(rect.height, 6); // raw 0 < 6 → clamped
    });

    test('normalizes inverted corners', () {
      final rect = spanDisplayRect(
        bbox: const <double>[40, 60, 10, 20],
        pageSize: const Size(100, 100),
        displaySize: const Size(100, 100),
      );
      expect(rect.left, 10);
      expect(rect.top, 20);
      expect(rect.width, 30);
      expect(rect.height, 40);
    });

    test('returns Rect.zero for a degenerate page size', () {
      final rect = spanDisplayRect(
        bbox: const <double>[1, 2, 3, 4],
        pageSize: Size.zero,
        displaySize: const Size(100, 100),
      );
      expect(rect, Rect.zero);
    });

    test('returns Rect.zero for a short bbox', () {
      final rect = spanDisplayRect(
        bbox: const <double>[1, 2, 3],
        pageSize: const Size(100, 100),
        displaySize: const Size(100, 100),
      );
      expect(rect, Rect.zero);
    });
  });

  group('spanRectForPage', () {
    test('maps a span onto the displayed page size', () {
      final page = _page(width: 612, height: 792);
      // Render at half width: 306 px wide → 0.5x scale.
      final display = displaySizeForWidth(page, 306);
      const span = EditableSpanModel(
        id: 'p1_b0_l0_s0',
        page: 1,
        text: 'Hello',
        bbox: <double>[100, 200, 300, 220],
        font: 'Helvetica',
        size: 12,
        color: 0x111111,
      );
      final rect = spanRectForPage(span: span, page: page, displaySize: display);
      expect(rect.left, closeTo(50, 1e-6)); // 100 * 0.5
      expect(rect.top, closeTo(100, 1e-6)); // 200 * 0.5
      expect(rect.width, closeTo(100, 1e-6)); // 200 * 0.5
      expect(rect.height, closeTo(10, 1e-6)); // 20 * 0.5
    });
  });
}
