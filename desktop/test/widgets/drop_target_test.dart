import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/file_picker_service.dart';
import 'package:qpic_desktop/widgets/drop_target.dart';

void main() {
  group('DropFileTarget.normalizedExtension', () {
    test('lowercases and strips the leading dot', () {
      expect(DropFileTarget.normalizedExtension('scan.PDF'), 'pdf');
      expect(DropFileTarget.normalizedExtension('photo.JPEG'), 'jpeg');
    });

    test('uses only the final extension of a multi-dot name', () {
      expect(DropFileTarget.normalizedExtension('report.final.pdf'), 'pdf');
    });

    test('returns empty for names without an extension', () {
      expect(DropFileTarget.normalizedExtension('README'), '');
      expect(DropFileTarget.normalizedExtension(''), '');
    });

    test('handles full paths, not just bare names', () {
      expect(
        DropFileTarget.normalizedExtension('/Users/me/docs/exam.pdf'),
        'pdf',
      );
    });
  });

  group('DropFileTarget.isAccepted (PDF-only target)', () {
    const accepted = DropFileTarget.pdfExtensions;

    test('accepts a PDF regardless of case (18.1)', () {
      expect(DropFileTarget.isAccepted('exam.pdf', accepted), isTrue);
      expect(DropFileTarget.isAccepted('exam.PDF', accepted), isTrue);
    });

    test('rejects a non-PDF file (18.3)', () {
      expect(DropFileTarget.isAccepted('page.png', accepted), isFalse);
      expect(DropFileTarget.isAccepted('photo.jpg', accepted), isFalse);
      expect(DropFileTarget.isAccepted('archive.zip', accepted), isFalse);
    });

    test('rejects extension-less files', () {
      expect(DropFileTarget.isAccepted('document', accepted), isFalse);
    });
  });

  group('DropFileTarget.isAccepted (images + PDF target)', () {
    const accepted = DropFileTarget.imagesAndPdfExtensions;

    test('accepts a PDF', () {
      expect(DropFileTarget.isAccepted('scan.pdf', accepted), isTrue);
    });

    test('accepts each supported image type (Rename Batch)', () {
      for (final ext in FilePickerService.imageExtensions) {
        expect(
          DropFileTarget.isAccepted('image.$ext', accepted),
          isTrue,
          reason: '.$ext should be accepted by the Rename Batch target',
        );
      }
    });

    test('rejects an unsupported type', () {
      expect(DropFileTarget.isAccepted('notes.txt', accepted), isFalse);
    });
  });

  group('imagesAndPdfExtensions composition', () {
    test('is the image extensions plus pdf', () {
      expect(
        DropFileTarget.imagesAndPdfExtensions,
        containsAll(FilePickerService.imageExtensions),
      );
      expect(DropFileTarget.imagesAndPdfExtensions, contains('pdf'));
    });
  });

  group('DropFileTarget widget', () {
    testWidgets('renders its child and shows no highlight while idle',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DropFileTarget.pdfOnly(
              onAccepted: (_) {},
              child: const Text('Drop a PDF'),
            ),
          ),
        ),
      );

      expect(find.text('Drop a PDF'), findsOneWidget);

      // The default overlay is an AnimatedContainer; while idle its
      // foreground border is transparent (no acceptance indicator yet).
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final decoration = container.foregroundDecoration! as BoxDecoration;
      expect(decoration.border!.top.color, Colors.transparent);
    });

    testWidgets('honors a custom overlay builder', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DropFileTarget.imagesAndPdf(
              onAccepted: (_) {},
              overlayBuilder: (context, isDragOver, child) => Column(
                children: <Widget>[
                  Text('dragOver=$isDragOver'),
                  child,
                ],
              ),
              child: const Text('Drop images'),
            ),
          ),
        ),
      );

      expect(find.text('dragOver=false'), findsOneWidget);
      expect(find.text('Drop images'), findsOneWidget);
      // No default overlay is used when a custom builder is supplied.
      expect(find.byType(AnimatedContainer), findsNothing);
    });
  });
}
