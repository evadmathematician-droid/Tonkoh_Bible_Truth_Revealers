import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/force_update/force_update_gate.dart';
import 'package:tbtrapp/force_update/force_update_manager.dart';

/// The app must be on screen from the first frame — never behind a logo /
/// spinner waiting for the network — and coming back from the background
/// must not bring a splash back.
void main() {
  // The gate's check() reaches for platform plugins that tests don't have;
  // the gate must not wait for it either way.
  final manager = ForceUpdateManager.instance;

  Widget app() => MaterialApp(
        builder: (context, child) => ForceUpdateGate(
          logo: const FlutterLogo(),
          child: child!,
        ),
        home: const Scaffold(body: Text('Audio feed')),
      );

  testWidgets('first frame shows the app before any policy decision',
      (tester) async {
    manager.status.value = null;
    await tester.pumpWidget(app());
    expect(find.text('Audio feed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(FlutterLogo), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    tester.takeException(); // plugin-less check() in tests
  });

  testWidgets('resume keeps the current screen (no splash, no reset)',
      (tester) async {
    await tester.pumpWidget(app());
    final state = tester.state(find.byType(ForceUpdateGate));
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    expect(find.text('Audio feed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // Same element: nothing above the app was rebuilt from scratch.
    expect(tester.state(find.byType(ForceUpdateGate)), same(state));
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();
  });
}
