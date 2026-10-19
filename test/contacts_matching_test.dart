import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/data/app_contact.dart';
import 'package:tbtrapp/data/contacts_repository.dart';

/// Contact sync with a fake phone book: every way people save Sierra Leone
/// numbers must find the registered account, without uploading anything but
/// account-key lookups.
void main() {
  // Registered accounts (strict E.164, as stored under users/).
  const registered = {
    '+23231932652', // the reported example
    '+23276123456',
    '+23288236249',
    '+447911123456',
  };

  final lookedUp = <Set<String>>[];
  Future<Map<String, LookupResult>> fakeLookup(Set<String> e164s) async {
    lookedUp.add(e164s);
    return {
      for (final n in e164s)
        n: registered.contains(n)
            ? LookupResult.registered
            : LookupResult.notRegistered,
    };
  }

  const phoneBook = <DeviceContact>[
    (name: 'Converter', numbers: ['031932652']),
    (name: 'Mum', numbers: ['030 000 000', '076-123-456']), // 2nd number matches
    (name: 'Prof', numbers: ['0023288236249']),
    (name: 'Prof (office)', numbers: ['+232 88 236 249']), // same account again
    (name: 'UK friend', numbers: ['+44 7911 123456']),
    (name: 'Not on app', numbers: ['077 999 888']),
    (name: 'Short code', numbers: ['121']),
    (name: 'Old format', numbers: ['+031932652']),
  ];

  test('matches every format and dedupes one account', () async {
    lookedUp.clear();
    final r = await matchContacts(
        contacts: phoneBook, defaultCountry: 'SL', lookup: fakeLookup);
    final onApp = {for (final c in r.book.onApp) c.uid: c.name};
    expect(onApp.keys.toSet(), registered);
    expect(onApp['+23276123456'], 'Mum');
    // One lookup round, each distinct number once.
    expect(lookedUp, hasLength(1));
    expect(lookedUp.single, containsAll(registered));
    expect(r.stats.contactsRead, phoneBook.length);
    expect(r.stats.numbersRead, 9);
    expect(r.stats.validNumbers, 6); // 121 is not a phone number
    expect(r.stats.onApp, 4);
    expect(r.book.notOnApp.map((c) => c.name),
        containsAll(['Not on app', 'Short code']));
  });

  test('own number is not counted as a contact on the app', () async {
    final r = await matchContacts(
        contacts: phoneBook,
        defaultCountry: 'SL',
        lookup: fakeLookup,
        selfId: '+23231932652');
    expect(r.stats.onApp, 3);
  });

  test('failed lookups keep previously matched people', () async {
    Future<Map<String, LookupResult>> offline(Set<String> e164s) async =>
        {for (final n in e164s) n: LookupResult.failed};
    const previous = ContactBook(onApp: [
      AppContact(name: 'Mum', phone: '+23276123456', uid: '+23276123456'),
    ]);
    final r = await matchContacts(
        contacts: phoneBook,
        defaultCountry: 'SL',
        lookup: offline,
        previous: previous);
    expect(r.book.onApp.map((c) => c.uid), ['+23276123456']);
    expect(r.stats.failedLookups, 6);
  });

  test('a Ghana user\'s local numbers use Ghana as default country', () async {
    Future<Map<String, LookupResult>> gh(Set<String> e164s) async => {
          for (final n in e164s)
            n: n == '+233244123456'
                ? LookupResult.registered
                : LookupResult.notRegistered,
        };
    final r = await matchContacts(
      contacts: const [(name: 'Kofi', numbers: ['024 412 3456'])],
      defaultCountry: 'GH',
      lookup: gh,
    );
    expect(r.book.onApp.single.uid, '+233244123456');
  });
}
