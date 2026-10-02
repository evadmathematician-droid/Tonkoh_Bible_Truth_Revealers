import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/data/contacts_repository.dart';

/// Reproduces the reported bug and proves the fix: a Sierra-Leone contact
/// saved locally must match the registered user's E.164, regardless of which
/// region the run guessed.
void main() {
  // Every region a run might land on — SL user, but the guess could be any
  // of these (blank profile country + West-African device locale, etc.).
  const regions = ['GH', 'NG', 'LR', 'GN', 'SL', 'US'];

  bool matches(String deviceRaw, String firebaseE164) {
    final dev = ContactsRepository.phoneKeys(deviceRaw, regions);
    final fb = ContactsRepository.phoneKeys(firebaseE164, regions);
    final exact = dev.e164s.intersection(fb.e164s).isNotEmpty;
    final loose = dev.nsn.intersection(fb.nsn).isNotEmpty;
    return exact || loose;
  }

  group('SL contact ↔ registered +23276123456', () {
    const user = '+23276123456';
    for (final saved in [
      '076123456',
      '076 123 456',
      '076-123-456',
      '+23276123456',
      '+232 76 123 456',
      '23276123456',
      '00232 76 123456',
      '76123456',
      '+232 076 123 456', // both CC and trunk 0
    ]) {
      test('saved as "$saved"', () {
        expect(matches(saved, user), isTrue,
            reason: 'device keys=${ContactsRepository.phoneKeys(saved, regions)} '
                'user keys=${ContactsRepository.phoneKeys(user, regions)}');
      });
    }
  });

  test('different people do NOT match', () {
    expect(matches('076123456', '+23277999888'), isFalse);
    expect(matches('076123456', '+233241234567'), isFalse); // GH user
  });

  test('un-parseable garbage still keys on digits', () {
    final k = ContactsRepository.phoneKeys('0 7 6 1 2 3 4 5 6 x', regions);
    expect(k.nsn.isNotEmpty || k.e164s.isNotEmpty, isTrue);
  });
}
