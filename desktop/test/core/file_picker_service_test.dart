import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/file_picker_service.dart';

void main() {
  group('FilePickerService', () {
    test('is const-constructible', () {
      expect(const FilePickerService(), isA<FilePickerService>());
    });

    group('imageExtensions (Rename Batch filter — Req 17.2)', () {
      test('includes the common image formats the engine accepts', () {
        expect(
          FilePickerService.imageExtensions,
          containsAll(<String>['png', 'jpg', 'jpeg', 'webp']),
        );
      });

      test('lists extensions lowercase and without a leading dot', () {
        for (final String ext in FilePickerService.imageExtensions) {
          expect(ext, equals(ext.toLowerCase()),
              reason: 'extensions must be lowercase for native matching');
          expect(ext.startsWith('.'), isFalse,
              reason: 'file_selector expects extensions without a dot');
        }
      });

      test('does not smuggle pdf into the image group', () {
        // PDF is added as a separate type group for Rename Batch, not folded
        // into the image extensions, so the PDF-only crop/tools filter (17.1)
        // can reuse a clean image list.
        expect(FilePickerService.imageExtensions, isNot(contains('pdf')));
      });
    });

    test('XTypeGroup is usable from the file_selector export surface', () {
      // Guards the import path the service relies on for its const type groups.
      const XTypeGroup group = XTypeGroup(
        label: 'PDF',
        extensions: <String>['pdf'],
      );
      expect(group.extensions, equals(<String>['pdf']));
    });
  });
}
