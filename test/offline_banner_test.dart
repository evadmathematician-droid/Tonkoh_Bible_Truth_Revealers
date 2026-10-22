import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/util/connection_status.dart';
import 'package:tbtrapp/widgets/offline_banner.dart';

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: () => setState(() => taps++),
        child: Text('taps $taps'),
      );
}

void main() {
  final offline = ConnectionStatus.instance.offline;
  tearDown(() => offline.value = false);

  testWidgets('hidden while online; appears offline without resetting the app',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => OfflineBanner(child: child!),
      home: const Scaffold(body: Center(child: _Counter())),
    ));
    expect(find.textContaining('No internet'), findsNothing);

    await tester.tap(find.text('taps 0'));
    await tester.pump();
    final state = tester.state(find.byType(_Counter));

    offline.value = true;
    await tester.pump();
    expect(find.textContaining('No internet'), findsOneWidget);
    expect(find.text('taps 1'), findsOneWidget);
    expect(tester.state(find.byType(_Counter)), same(state));

    offline.value = false;
    await tester.pump();
    expect(find.textContaining('No internet'), findsNothing);
    expect(tester.state(find.byType(_Counter)), same(state));
  });
}
