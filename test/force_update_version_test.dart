import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/force_update/force_update_service.dart';

void main() {
  int? cmp(String a, String b) => ForceUpdateService.compareVersions(a, b);

  test('compares each part numerically, not as text', () {
    expect(cmp('1.10.0', '1.9.0'), greaterThan(0));
    expect(cmp('1.9.0', '1.10.0'), lessThan(0));
    expect(cmp('2.0.0', '1.99.99'), greaterThan(0));
    expect(cmp('3.2.1', '3.2.10'), lessThan(0));
  });

  test('equal versions compare as 0', () {
    expect(cmp('1.4.0', '1.4.0'), 0);
    expect(cmp('1.4', '1.4.0'), 0);
    expect(cmp('1', '1.0.0'), 0);
  });

  test('ignores build numbers, pre-release tags and a leading v', () {
    expect(cmp('3.2.1+24', '3.2.1'), 0);
    expect(cmp('v1.4.0', '1.4.0'), 0);
    expect(cmp(' 1.4.0 ', '1.4.0'), 0);
    expect(cmp('1.4.0-beta', '1.4.0'), 0);
  });

  test('returns null for anything that is not a version', () {
    expect(cmp('1.4.0', ''), isNull);
    expect(cmp('1.4.0', 'latest'), isNull);
    expect(cmp('1.4.0', '1.4.x'), isNull);
    expect(cmp('1.4.0', '1.2.3.4'), isNull);
    expect(cmp('1.4.0', '1..4'), isNull);
  });
}
