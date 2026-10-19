import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/data/app_contact.dart';
import 'package:tbtrapp/data/display_names.dart';

void main() {
  group('resolveDisplayName', () {
    const saved = {'+23276123456': 'Pastor John'};

    test('saved number shows my saved name', () {
      expect(resolveDisplayName('+23276123456', saved), 'Pastor John');
    });

    test('unsaved number shows only the number, never a profile name', () {
      final shown = resolveDisplayName('+23277999888', saved);
      expect(shown, startsWith('+232'));
      expect(shown.replaceAll(' ', ''), '+23277999888');
    });

    test('blank saved name falls back to the number', () {
      expect(
        resolveDisplayName('+23276123456', {'+23276123456': '  '})
            .replaceAll(' ', ''),
        '+23276123456',
      );
    });

    test('empty id', () {
      expect(resolveDisplayName('', saved), 'Unknown');
    });
  });

  group('formatPhoneForDisplay', () {
    test('groups an international number', () {
      final f = formatPhoneForDisplay('+23276123456');
      expect(f, startsWith('+232 '));
      expect(f.replaceAll(' ', ''), '+23276123456');
    });

    test('repairs a stored national number before showing it', () {
      expect(formatPhoneForDisplay('076123456'), '+232 76 123 456');
    });

    test('leaves non-phone text alone', () {
      expect(formatPhoneForDisplay('Pastor John'), 'Pastor John');
    });
  });

  group('savedNamesFrom', () {
    test('keys by uid and phone, skips blank names', () {
      final map = savedNamesFrom(const [
        AppContact(name: 'Mum', phone: '+23276000001', uid: '+23276000001'),
        AppContact(name: 'Ama', phone: '+233200000002', uid: 'legacy-id'),
        AppContact(name: '   ', phone: '+23276000003', uid: '+23276000003'),
      ]);
      expect(map['+23276000001'], 'Mum');
      expect(map['legacy-id'], 'Ama');
      expect(map['+233200000002'], 'Ama');
      expect(map.containsKey('+23276000003'), isFalse);
    });
  });

  test('DisplayNames.nameFor follows the saved map', () {
    final names = DisplayNames.instance;
    names.debugSetSaved({'+23276000001': 'Mum'});
    expect(names.nameFor('+23276000001'), 'Mum');
    expect(names.isSaved('+23276000002'), isFalse);
    expect(names.nameFor('+23276000002').replaceAll(' ', ''), '+23276000002');
  });
}
