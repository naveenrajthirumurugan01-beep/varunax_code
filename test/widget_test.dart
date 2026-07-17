import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:varuna_x/main.dart';

void main() {
  testWidgets('VarunaX App smoke test - login screen renders', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const VarunaXApp());

    // Verify that the login screen title and button are present.
    expect(find.text('Varuna X'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Log In'), findsOneWidget);
  });
}

