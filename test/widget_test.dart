import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tbtrapp/main.dart';

void main() {
  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const TBTRApp());
    await tester.pump();

    // Replace with something that actually exists in your app,
    // e.g. the app bar title:
    expect(find.text('TONKOH  BIBLE  TRUTH  REVEALERS'), findsOneWidget);
  });
}