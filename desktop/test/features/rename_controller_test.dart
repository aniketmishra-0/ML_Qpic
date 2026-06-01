// Unit tests for RenameController bounds enforcement and token expansion
// (Requirements 12.1, 12.2).
//
// These verify the controller clamps every value to the engine's accepted
// bounds, that the token expansion logic mirrors the web UI's `buildStem` /
// `planRenames`, and that the preview is triggered on control changes.

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/rename/rename_controller.dart';

void main() {
  group('RenameController defaults', () {
    test('starts in a valid, in-bounds state', () {
      final c = RenameController();
      expect(c.pattern, '#');
      expect(c.start, RenameBounds.startDefault);
      expect(c.padding, RenameBounds.paddingDefault);
      expect(c.outputFormat, RenameOutputFormat.original);
      expect(c.jpgQuality, RenameBounds.jpgQualityDefault);
      expect(c.itemCount, 0);
      expect(c.previewItems, isNull);
      expect(c.previewError, isNull);
      expect(c.previewLoading, isFalse);
    });
  });

  group('Start number bounds 0–1,000,000', () {
    test('clamps below the minimum to 0', () {
      final c = RenameController()..start = -5;
      expect(c.start, 0);
    });

    test('clamps above the maximum to 1,000,000', () {
      final c = RenameController()..start = 2000000;
      expect(c.start, 1000000);
    });

    test('keeps an in-range value', () {
      final c = RenameController()..start = 500;
      expect(c.start, 500);
    });
  });

  group('Padding bounds 0–12', () {
    test('clamps a negative value to 0', () {
      final c = RenameController()..padding = -1;
      expect(c.padding, 0);
    });

    test('clamps above the maximum to 12', () {
      final c = RenameController()..padding = 20;
      expect(c.padding, 12);
    });

    test('keeps an in-range value', () {
      final c = RenameController()..padding = 4;
      expect(c.padding, 4);
    });
  });

  group('JPG quality bounds 1–100', () {
    test('clamps 0 up to 1', () {
      final c = RenameController()..jpgQuality = 0;
      expect(c.jpgQuality, 1);
    });

    test('clamps above the maximum to 100', () {
      final c = RenameController()..jpgQuality = 150;
      expect(c.jpgQuality, 100);
    });

    test('keeps an in-range value', () {
      final c = RenameController()..jpgQuality = 85;
      expect(c.jpgQuality, 85);
    });
  });

  group('Output format', () {
    test('all format values are valid engine values', () {
      const expected = <String>{'original', 'png', 'jpg', 'jpeg', 'webp'};
      for (final format in RenameOutputFormat.values) {
        expect(expected, contains(format.value));
      }
    });
  });

  group('Token expansion (buildStem)', () {
    test('# is replaced by the number', () {
      final c = RenameController()..pattern = 'Q#';
      final item = RenameItem(name: 'photo.jpg', sizeBytes: 1024);
      expect(c.buildStem(item, 1), 'Q1');
      expect(c.buildStem(item, 42), 'Q42');
    });

    test('zero-padding is applied to the number', () {
      final c = RenameController()
        ..pattern = 'img_#'
        ..padding = 4;
      final item = RenameItem(name: 'photo.jpg', sizeBytes: 0);
      expect(c.buildStem(item, 1), 'img_0001');
      expect(c.buildStem(item, 99), 'img_0099');
    });

    test('(name) token is replaced by the stem', () {
      final c = RenameController()..pattern = '(name)_#';
      final item = RenameItem(name: 'sunset.png', sizeBytes: 0);
      expect(c.buildStem(item, 1), 'sunset_1');
    });

    test('(ext) token is replaced by the extension', () {
      final c = RenameController()..pattern = '#_(ext)';
      final item = RenameItem(name: 'photo.jpg', sizeBytes: 0);
      expect(c.buildStem(item, 5), '5_jpg');
    });

    test('(fullname) token is replaced by the full filename', () {
      final c = RenameController()..pattern = '(fullname)_#';
      final item = RenameItem(name: 'my_photo.png', sizeBytes: 0);
      expect(c.buildStem(item, 1), 'my_photo.png_1');
    });

    test('(width) and (height) tokens are replaced', () {
      final c = RenameController()..pattern = '#_(width)x(height)';
      final item = RenameItem(name: 'img.png', width: 800, height: 600, sizeBytes: 0);
      expect(c.buildStem(item, 1), '1_800x600');
    });

    test('(n) token is replaced by the number (case-insensitive)', () {
      final c = RenameController()..pattern = 'file_(N)';
      final item = RenameItem(name: 'img.png', sizeBytes: 0);
      expect(c.buildStem(item, 7), 'file_7');
    });

    test('pattern with no token appends the number', () {
      final c = RenameController()..pattern = 'constant';
      final item = RenameItem(name: 'img.png', sizeBytes: 0);
      expect(c.buildStem(item, 3), 'constant3');
    });

    test('empty pattern defaults to #', () {
      final c = RenameController()..pattern = '';
      final item = RenameItem(name: 'img.png', sizeBytes: 0);
      expect(c.buildStem(item, 1), '1');
    });

    test('filesystem-unsafe characters are sanitized', () {
      final c = RenameController()..pattern = 'file:#/test';
      final item = RenameItem(name: 'img.png', sizeBytes: 0);
      // # is replaced by number, : and / are sanitized to _
      final result = c.buildStem(item, 1);
      expect(result.contains(':'), isFalse);
      expect(result.contains('/'), isFalse);
    });
  });

  group('planRenames', () {
    test('produces unique names for duplicate stems', () {
      final c = RenameController()..pattern = 'same';
      c.addItems([
        RenameItem(name: 'a.png', sizeBytes: 0),
        RenameItem(name: 'b.png', sizeBytes: 0),
        RenameItem(name: 'c.png', sizeBytes: 0),
      ]);
      final names = c.planRenames();
      // All names should be unique.
      expect(names.toSet().length, names.length);
    });

    test('uses the correct start number', () {
      final c = RenameController()
        ..pattern = 'Q#'
        ..start = 5;
      c.addItems([
        RenameItem(name: 'a.png', sizeBytes: 0),
        RenameItem(name: 'b.png', sizeBytes: 0),
      ]);
      final names = c.planRenames();
      expect(names[0], 'Q5.png');
      expect(names[1], 'Q6.png');
    });

    test('respects output format for extension', () {
      final c = RenameController()
        ..pattern = '#'
        ..outputFormat = RenameOutputFormat.webp;
      c.addItems([
        RenameItem(name: 'photo.jpg', sizeBytes: 0),
      ]);
      final names = c.planRenames();
      expect(names[0], '1.webp');
    });

    test('original format keeps the file extension', () {
      final c = RenameController()
        ..pattern = '#'
        ..outputFormat = RenameOutputFormat.original;
      c.addItems([
        RenameItem(name: 'photo.jpg', sizeBytes: 0),
        RenameItem(name: 'image.png', sizeBytes: 0),
      ]);
      final names = c.planRenames();
      expect(names[0], '1.jpg');
      expect(names[1], '2.png');
    });
  });

  group('outputExtension', () {
    test('original keeps the file extension', () {
      final c = RenameController()..outputFormat = RenameOutputFormat.original;
      expect(c.outputExtension('photo.jpg'), 'jpg');
      expect(c.outputExtension('image.PNG'), 'png');
    });

    test('forced format overrides the extension', () {
      final c = RenameController()..outputFormat = RenameOutputFormat.webp;
      expect(c.outputExtension('photo.jpg'), 'webp');
    });

    test('jpg and jpeg both produce jpg', () {
      final c1 = RenameController()..outputFormat = RenameOutputFormat.jpg;
      final c2 = RenameController()..outputFormat = RenameOutputFormat.jpeg;
      expect(c1.outputExtension('img.png'), 'jpg');
      expect(c2.outputExtension('img.png'), 'jpg');
    });
  });

  group('Item management', () {
    test('addItems increases count', () {
      final c = RenameController();
      c.addItems([
        RenameItem(name: 'a.png', sizeBytes: 100),
        RenameItem(name: 'b.jpg', sizeBytes: 200),
      ]);
      expect(c.itemCount, 2);
    });

    test('removeItem decreases count', () {
      final c = RenameController();
      c.addItems([
        RenameItem(name: 'a.png', sizeBytes: 100),
        RenameItem(name: 'b.jpg', sizeBytes: 200),
      ]);
      c.removeItem(0);
      expect(c.itemCount, 1);
      expect(c.items[0].name, 'b.jpg');
    });

    test('clearItems resets to empty', () {
      final c = RenameController();
      c.addItems([RenameItem(name: 'a.png', sizeBytes: 100)]);
      c.clearItems();
      expect(c.itemCount, 0);
    });

    test('removeItem with invalid index does nothing', () {
      final c = RenameController();
      c.addItems([RenameItem(name: 'a.png', sizeBytes: 100)]);
      c.removeItem(-1);
      c.removeItem(5);
      expect(c.itemCount, 1);
    });
  });

  group('Change notification', () {
    test('notifies listeners on control changes', () {
      final c = RenameController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.pattern = 'new_#';
      c.start = 10;
      c.padding = 3;
      c.outputFormat = RenameOutputFormat.png;
      c.jpgQuality = 50;
      expect(notifications, 5);
    });

    test('does not notify when the clamped value is unchanged', () {
      final c = RenameController()..padding = 12;
      var notifications = 0;
      c.addListener(() => notifications++);
      // Already at max; another over-max write yields the same 12.
      c.padding = 20;
      expect(notifications, 0);
    });

    test('notifies on addItems', () {
      final c = RenameController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.addItems([RenameItem(name: 'a.png', sizeBytes: 0)]);
      expect(notifications, greaterThan(0));
    });
  });
}
