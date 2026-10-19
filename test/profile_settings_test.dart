import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tbtrapp/data/profile_settings_repository.dart';
import 'package:tbtrapp/data/user_profile.dart';
import 'package:tbtrapp/screens/profile/settings_screen.dart';

/// A tiny in-memory database that applies multi-path updates the way the
/// Realtime Database does: only the listed leaves change.
class FakeBackend implements ProfileBackend {
  bool online = true;
  bool reject = false;
  final Map<String, dynamic> db;
  final List<Map<String, Object?>> calls = [];

  FakeBackend(this.db);

  @override
  Future<bool> isOnline() async => online;

  @override
  Future<void> updatePaths(Map<String, Object?> paths) async {
    if (reject) throw Exception('permission-denied');
    calls.add(paths);
    paths.forEach((path, value) {
      final parts = path.split('/');
      Map<String, dynamic> node = db;
      for (final p in parts.take(parts.length - 1)) {
        node = (node[p] ??= <String, dynamic>{}) as Map<String, dynamic>;
      }
      node[parts.last] = value;
    });
  }

  @override
  Future<Map<String, String>> chatPartners(String myUid) async => {
        '+23276123456_+23288236249': '+23276123456',
      };
}

Map<String, dynamic> sampleDb() => {
      'users': {
        '+23288236249': <String, dynamic>{
          'uid': '+23288236249',
          'phone': '+23288236249',
          'name': 'Prof.',
          'photoUrl': 'OLDPHOTO',
          'oneSignalId': 'push-123',
          'authUid': 'auth-abc',
          'activeDeviceId': 'device-1',
          'country': 'SL',
        },
      },
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('name rules', () {
    test('required, 2–40 characters, extra spaces trimmed', () {
      expect(ProfileSettingsRepository.validateName(''), isNotNull);
      expect(ProfileSettingsRepository.validateName('   '), isNotNull);
      expect(ProfileSettingsRepository.validateName('A'), isNotNull);
      expect(ProfileSettingsRepository.validateName('Al'), isNull);
      expect(ProfileSettingsRepository.validateName('x' * 40), isNull);
      expect(ProfileSettingsRepository.validateName('x' * 41), isNotNull);
      expect(ProfileSettingsRepository.cleanName('  Pastor   John  '),
          'Pastor John');
    });
  });

  group('save', () {
    test('updates only name/updatedAt and keeps every other field', () async {
      final backend = FakeBackend(sampleDb());
      final repo = ProfileSettingsRepository(
          backend: backend, clock: () => DateTime.fromMillisecondsSinceEpoch(5));
      final r = await repo.save(uid: '+23288236249', name: '  Pst.  Evangelist ');
      expect(r, ProfileSaveResult.saved);
      expect(backend.calls.first.keys,
          unorderedEquals(['users/+23288236249/name', 'users/+23288236249/updatedAt']));
      final me = backend.db['users']['+23288236249'] as Map;
      expect(me['name'], 'Pst. Evangelist');
      expect(me['updatedAt'], 5);
      expect(me['oneSignalId'], 'push-123');
      expect(me['authUid'], 'auth-abc');
      expect(me['activeDeviceId'], 'device-1');
      expect(me['photoUrl'], 'OLDPHOTO');
      expect(await repo.pending(), isNull);
    });

    test('photo change and removal write photoUrl only', () async {
      final backend = FakeBackend(sampleDb());
      final repo = ProfileSettingsRepository(backend: backend);
      await repo.save(uid: '+23288236249', photoUrl: 'NEWJPEG');
      expect((backend.db['users']['+23288236249'] as Map)['photoUrl'], 'NEWJPEG');
      await repo.save(uid: '+23288236249', photoUrl: '');
      expect((backend.db['users']['+23288236249'] as Map)['photoUrl'], '');
      expect((backend.db['users']['+23288236249'] as Map)['name'], 'Prof.');
    });

    test('also refreshes my name in chat partners\' chat lists', () async {
      final backend = FakeBackend(sampleDb());
      final repo = ProfileSettingsRepository(backend: backend);
      await repo.save(uid: '+23288236249', name: 'New Name');
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls.last.keys,
          ['userChats/+23276123456/+23276123456_+23288236249/otherName']);
    });

    test('offline: queued, then sent when back online', () async {
      final backend = FakeBackend(sampleDb())..online = false;
      final repo = ProfileSettingsRepository(backend: backend);
      expect(await repo.save(uid: '+23288236249', name: 'Offline Name'),
          ProfileSaveResult.queuedOffline);
      expect(backend.calls, isEmpty);
      expect((await repo.pending())!.name, 'Offline Name');
      // A second offline edit (photo) is merged with the first.
      await repo.save(uid: '+23288236249', photoUrl: 'P2');
      backend.online = true;
      expect(await repo.flushPending(), isTrue);
      final me = backend.db['users']['+23288236249'] as Map;
      expect(me['name'], 'Offline Name');
      expect(me['photoUrl'], 'P2');
      expect(await repo.pending(), isNull);
    });

    test('rejected write keeps the edit queued and reports the error',
        () async {
      final backend = FakeBackend(sampleDb())..reject = true;
      final repo = ProfileSettingsRepository(backend: backend);
      await expectLater(
          repo.save(uid: '+23288236249', name: 'Kept'), throwsException);
      expect((await repo.pending())!.name, 'Kept');
    });
  });

  group('Settings screen', () {
    final me = UserProfile(
      uid: '+23288236249',
      name: 'Prof.',
      phone: '+23288236249',
      country: 'SL',
      photoUrl: '',
      createdAt: 0,
    );

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(
          home: SettingsScreen(
            initialProfile: me,
            repository: ProfileSettingsRepository(backend: FakeBackend(sampleDb())),
          ),
        ));

    FilledButton saveButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const Key('settingsSave')));

    testWidgets('Save is disabled until something changes', (tester) async {
      await pump(tester);
      expect(saveButton(tester).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('settingsName')), 'Pst. Evan');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);
      // Back to the same name (extra spaces ignored) → nothing to save.
      await tester.enterText(find.byKey(const Key('settingsName')), ' Prof. ');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNull);
    });

    testWidgets('invalid name shows an error and disables Save', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const Key('settingsName')), 'A');
      await tester.pump();
      expect(find.text('At least 2 characters'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
    });

    testWidgets('number and country are shown read-only', (tester) async {
      await pump(tester);
      expect(find.text('+232 88 236 249'), findsOneWidget);
      expect(find.textContaining('Sierra Leone (SL) +232'), findsOneWidget);
      expect(find.byKey(const Key('settingsCopyPhone')), findsOneWidget);
      expect(find.text('This is your T.B.T.R number'), findsOneWidget);
    });
  });
}
