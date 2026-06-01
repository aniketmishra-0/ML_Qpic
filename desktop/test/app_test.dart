import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/app.dart';

void main() {
  group('QpicApp skeleton', () {
    testWidgets('builds a MaterialApp titled Qpic', (tester) async {
      await tester.pumpWidget(const QpicApp());

      final appFinder = find.byType(MaterialApp);
      expect(appFinder, findsOneWidget);

      final MaterialApp app = tester.widget(appFinder);
      expect(app.title, 'Qpic');
      expect(app.debugShowCheckedModeBanner, isFalse);
    });

    testWidgets('provides light and dark themes following the system mode',
        (tester) async {
      await tester.pumpWidget(const QpicApp());

      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.theme, isNotNull);
      expect(app.darkTheme, isNotNull);
      expect(app.themeMode, ThemeMode.system);
    });

    testWidgets('renders a Scaffold home surface', (tester) async {
      await tester.pumpWidget(const QpicApp());
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });
}
