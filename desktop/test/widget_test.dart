// Top-level smoke test for the Qpic desktop client.
//
// Replaces the default `flutter create` counter-app template (which referenced
// a non-existent `MyApp`) with a smoke test against the real [QpicApp] root.
// Deeper app/shell behaviour lives in `test/app_test.dart` and the per-feature
// test suites.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/app.dart';

void main() {
  testWidgets('QpicApp builds its MaterialApp shell', (tester) async {
    await tester.pumpWidget(const QpicApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
