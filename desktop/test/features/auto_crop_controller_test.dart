// Unit tests for AutoCropController bounds enforcement (Requirement 5.3).
//
// These verify the controller clamps/truncates every value to the engine's
// accepted bounds and that the toggle/selector mappings produce the exact
// engine query values (`marker_style`, `image_format`, `use_ai`). The submit
// guards and request construction belong to tasks 9.2 / 9.4, so they are not
// exercised here.

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/auto_crop/auto_crop_controller.dart';

void main() {
  group('AutoCropController defaults', () {
    test('start in a valid, in-bounds state', () {
      final c = AutoCropController();
      expect(c.hasQuestions, isTrue);
      expect(c.hasAnswers, isTrue);
      expect(c.questionPages, isEmpty);
      expect(c.answerPages, isEmpty);
      expect(c.smartMode, isFalse);
      expect(c.onlineMode, isFalse);
      expect(c.answerSheet, isTrue);
      expect(c.numbering, NumberingMode.autoDetect);
      expect(c.questionPrefix, 'Q');
      expect(c.solutionPrefix, 'S');
      expect(c.startNumber, AutoCropBounds.startNumberDefault);
      expect(c.imageFormat, CropImageFormat.png);
      expect(c.jpgQuality, AutoCropBounds.jpgQualityDefault);
      expect(c.dpi, AutoCropBounds.dpiDefault);
      expect(c.padding, AutoCropBounds.paddingDefault);
    });
  });

  group('DPI bounds 72–600', () {
    test('clamps below the minimum to 72', () {
      final c = AutoCropController()..dpi = 10;
      expect(c.dpi, 72);
    });

    test('clamps above the maximum to 600', () {
      final c = AutoCropController()..dpi = 5000;
      expect(c.dpi, 600);
    });

    test('keeps an in-range value', () {
      final c = AutoCropController()..dpi = 300;
      expect(c.dpi, 300);
    });
  });

  group('Padding bounds 0–200', () {
    test('clamps a negative value to 0', () {
      final c = AutoCropController()..padding = -50;
      expect(c.padding, 0);
    });

    test('clamps above the maximum to 200', () {
      final c = AutoCropController()..padding = 999;
      expect(c.padding, 200);
    });
  });

  group('Start number bounds 1–100000', () {
    test('clamps 0 up to 1', () {
      final c = AutoCropController()..startNumber = 0;
      expect(c.startNumber, 1);
    });

    test('clamps above the maximum to 100000', () {
      final c = AutoCropController()..startNumber = 999999;
      expect(c.startNumber, 100000);
    });
  });

  group('JPG quality bounds 1–100', () {
    test('clamps 0 up to 1', () {
      final c = AutoCropController()..jpgQuality = 0;
      expect(c.jpgQuality, 1);
    });

    test('clamps above the maximum to 100', () {
      final c = AutoCropController()..jpgQuality = 150;
      expect(c.jpgQuality, 100);
    });
  });

  group('Prefix max length 10', () {
    test('truncates an over-long question prefix', () {
      final c = AutoCropController()..questionPrefix = 'ABCDEFGHIJKLMNOP';
      expect(c.questionPrefix.length, 10);
      expect(c.questionPrefix, 'ABCDEFGHIJ');
    });

    test('truncates an over-long solution prefix', () {
      final c = AutoCropController()..solutionPrefix = 'SOLUTION_PREFIX_TOO_LONG';
      expect(c.solutionPrefix.length, 10);
      expect(c.solutionPrefix, 'SOLUTION_P');
    });

    test('keeps a short prefix unchanged', () {
      final c = AutoCropController()..questionPrefix = 'Ques';
      expect(c.questionPrefix, 'Ques');
    });
  });

  group('marker_style mapping (auto / q / numbered)', () {
    test('Auto-detect → auto', () {
      final c = AutoCropController()..numbering = NumberingMode.autoDetect;
      expect(c.markerStyle, 'auto');
    });

    test('Q-only → q', () {
      final c = AutoCropController()..numbering = NumberingMode.qOnly;
      expect(c.markerStyle, 'q');
    });

    test('Numbered → numbered', () {
      final c = AutoCropController()..numbering = NumberingMode.numbered;
      expect(c.markerStyle, 'numbered');
    });

    test('marker_style is always one of the accepted values', () {
      for (final mode in NumberingMode.values) {
        final c = AutoCropController()..numbering = mode;
        expect(<String>{'auto', 'q', 'numbered'}, contains(c.markerStyle));
      }
    });
  });

  group('image_format mapping (png / jpg)', () {
    test('PNG → png', () {
      final c = AutoCropController()..imageFormat = CropImageFormat.png;
      expect(c.imageFormatValue, 'png');
    });

    test('JPG → jpg', () {
      final c = AutoCropController()..imageFormat = CropImageFormat.jpg;
      expect(c.imageFormatValue, 'jpg');
    });

    test('image_format is always png or jpg', () {
      for (final format in CropImageFormat.values) {
        final c = AutoCropController()..imageFormat = format;
        expect(<String>{'png', 'jpg'}, contains(c.imageFormatValue));
      }
    });
  });

  group('use_ai mirrors Online mode', () {
    test('off by default', () {
      expect(AutoCropController().useAi, isFalse);
    });

    test('true when Online mode is on', () {
      final c = AutoCropController()..onlineMode = true;
      expect(c.useAi, isTrue);
    });
  });

  group('change notification', () {
    test('notifies listeners on a value change', () {
      final c = AutoCropController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.dpi = 300;
      c.padding = 40;
      c.smartMode = true;
      expect(notifications, 3);
    });

    test('does not notify when the clamped value is unchanged', () {
      final c = AutoCropController()..dpi = 600;
      var notifications = 0;
      c.addListener(() => notifications++);
      // Already clamped to the max; another over-max write yields the same 600.
      c.dpi = 9000;
      expect(notifications, 0);
    });

    test('page-range values are stored verbatim (untrimmed)', () {
      final c = AutoCropController()..questionPages = '  1-5  ';
      expect(c.questionPages, '  1-5  ');
    });
  });
}
