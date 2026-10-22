import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/widgets/presence_label.dart';

void main() {
  final now = DateTime(2026, 10, 22, 9, 30);
  int at(DateTime d) => d.millisecondsSinceEpoch;

  test('same calendar day is "today" with the time', () {
    expect(formatLastSeen(at(DateTime(2026, 10, 22, 0, 5)), now: now),
        'today at 12:05 AM');
  });

  test('late last night is "yesterday", even under 24 hours ago', () {
    expect(formatLastSeen(at(DateTime(2026, 10, 21, 23, 50)), now: now),
        'yesterday at 11:50 PM');
  });

  test('older than yesterday shows the date', () {
    expect(formatLastSeen(at(DateTime(2026, 10, 20, 15, 0)), now: now),
        '10/20');
  });
}
