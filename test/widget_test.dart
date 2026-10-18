import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tbtrapp/navigation/app_router.dart';

// The full app can't boot in a widget test (Firebase, OneSignal and the
// audio service need a device), so this smoke-tests a standalone screen.
void main() {
  testWidgets('Coming-soon screen shows its label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ComingSoonScreen('Bible Facts')),
    );

    expect(find.text('Bible Facts'), findsOneWidget);
    expect(find.text('Bible Facts is coming soon.'), findsOneWidget);
  });
}
