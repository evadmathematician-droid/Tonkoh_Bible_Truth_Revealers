import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/screens/components/phone_number_field.dart';
import 'package:tbtrapp/screens/profile/profile_setup_screen.dart';

/// The registration screen crashed on a 360 dp phone ("An InputDecorator
/// … cannot have an unbounded width"): the country picker sat in a Row with
/// no width limit. Pump it on small and normal phones, with large text.
void main() {
  const widths = [320.0, 360.0, 411.0];
  const scales = [1.0, 1.3];

  Future<void> pumpAt(WidgetTester tester, double width, double scale,
      Widget child) async {
    tester.view.physicalSize = Size(width * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: (context, w) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: w!,
      ),
      home: child,
    ));
    await tester.pump();
  }

  for (final w in widths) {
    for (final s in scales) {
      testWidgets('PhoneNumberField at $w dp, text ×$s', (tester) async {
        await pumpAt(
            tester,
            w,
            s,
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: PhoneNumberField(onChanged: (_, __) {}),
              ),
            ));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('phoneCountryPicker')), findsOneWidget);
        // Picker and number box side by side, both inside the screen.
        final picker = tester.getRect(find.byKey(const Key('phoneCountryPicker')));
        final number = tester.getRect(find.byKey(const Key('phoneNumberInput')));
        expect(picker.right, lessThanOrEqualTo(number.left));
        expect(number.right, lessThanOrEqualTo(w));

        await tester.enterText(find.byKey(const Key('phoneNumberInput')), '076123456');
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Your number: +232 76 123 456'), findsOneWidget);
      });

      testWidgets('ProfileSetupScreen at $w dp, text ×$s', (tester) async {
        await pumpAt(tester, w, s, ProfileSetupScreen(onDone: () {}));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('phoneCountryPicker')), findsOneWidget);
        expect(find.byKey(const Key('phoneNumberInput')), findsOneWidget);
      });
    }
  }
}
