import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tbtrapp/admin/admin_pin.dart';

void main() {
  late DateTime now;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 10, 19, 12);
  });

  AdminPin pin({Future<String?> Function()? remote}) => AdminPin(
        clock: () => now,
        remoteHash: remote ?? () async => AdminPin.fallbackHash,
      );

  test('the stored hash is SHA-256 of 2222, not the plain PIN', () {
    expect(AdminPin.hashOf('2222'), AdminPin.fallbackHash);
  });

  test('2222 opens Admin and is remembered for the session', () async {
    final p = pin();
    expect(p.unlockedThisSession, isFalse);
    expect(await p.verify('2222'), isNull);
    expect(p.unlockedThisSession, isTrue);
  });

  test('other PINs are wrong', () async {
    final p = pin();
    for (final wrong in ['1111', '0000', '2223', '9999']) {
      expect(await p.verify(wrong), startsWith('Wrong PIN'));
    }
    expect(p.unlockedThisSession, isFalse);
  });

  test('not 4 digits is rejected without counting as a try', () async {
    final p = pin();
    expect(await p.verify('22'), 'Enter the 4-digit PIN.');
    expect(await p.verify('abcd'), 'Enter the 4-digit PIN.');
    expect(await p.verify('2222'), isNull);
  });

  test('5 wrong tries lock for 30 seconds, even for the right PIN', () async {
    final p = pin();
    for (var i = 0; i < 4; i++) {
      expect(await p.verify('1234'), startsWith('Wrong PIN'));
    }
    expect(await p.verify('1234'), contains('wait 30 seconds'));
    expect(p.lockRemaining, const Duration(seconds: 30));
    expect(await p.verify('2222'), startsWith('Too many wrong tries'));
    now = now.add(const Duration(seconds: 29));
    expect(await p.verify('2222'), startsWith('Too many wrong tries'));
    now = now.add(const Duration(seconds: 2));
    expect(p.lockRemaining, isNull);
    expect(await p.verify('2222'), isNull);
  });

  test('a PIN changed in the database replaces 2222, also offline later',
      () async {
    final newHash = AdminPin.hashOf('4321');
    var online = true;
    final p = pin(remote: () async {
      if (!online) throw Exception('offline');
      return newHash;
    });
    expect(await p.verify('2222'), startsWith('Wrong PIN'));
    expect(await p.verify('4321'), isNull);
    online = false; // the phone remembers the last hash it saw
    final again = pin(remote: () async => throw Exception('offline'));
    expect(await again.verify('4321'), isNull);
    expect(await pin(remote: () async => throw Exception('offline'))
        .verify('2222'), startsWith('Wrong PIN'));
  });

  test('database value missing or unreachable → built-in hash (2222)',
      () async {
    expect(await pin(remote: () async => null).verify('2222'), isNull);
    expect(await pin(remote: () async => throw Exception('no network'))
        .verify('2222'), isNull);
  });
}
