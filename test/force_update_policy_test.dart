import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tbtrapp/force_update/force_update_manager.dart';

void main() {
  const allowed = ForceUpdateDecision.allowed;
  const updateRequired = ForceUpdateDecision.updateRequired;
  const maintenance = ForceUpdateDecision.maintenance;

  group('evaluate', () {
    test('blocks a version code below the minimum when forced', () {
      const p = ForceUpdatePolicy(
          forceUpdate: true, minVersionCode: 30, latestVersionCode: 30);
      expect(p.evaluate(24), updateRequired);
      expect(p.evaluate(29), updateRequired);
    });

    test('allows the minimum version and anything newer', () {
      const p = ForceUpdatePolicy(
          forceUpdate: true, minVersionCode: 30, latestVersionCode: 31);
      expect(p.evaluate(30), allowed);
      expect(p.evaluate(31), allowed);
      expect(p.evaluate(100), allowed);
    });

    test('compares as integers, so 10 is newer than 9', () {
      const p = ForceUpdatePolicy(forceUpdate: true, minVersionCode: 10);
      expect(p.evaluate(9), updateRequired);
      expect(p.evaluate(10), allowed);
    });

    test('force_update false never blocks an update', () {
      const p = ForceUpdatePolicy(forceUpdate: false, minVersionCode: 999);
      expect(p.evaluate(1), allowed);
    });

    test('never blocks when the installed code is unknown', () {
      const p = ForceUpdatePolicy(forceUpdate: true, minVersionCode: 30);
      expect(p.evaluate(null), allowed);
    });

    test('ignores a minimum above the latest published version', () {
      // Misconfiguration: nothing newer exists to install.
      const p = ForceUpdatePolicy(
          forceUpdate: true, minVersionCode: 40, latestVersionCode: 35);
      expect(p.evaluate(24), allowed);
    });

    test('maintenance mode blocks every version', () {
      const p = ForceUpdatePolicy(maintenanceMode: true);
      expect(p.evaluate(24), maintenance);
      expect(p.evaluate(1000), maintenance);
      expect(p.evaluate(null), maintenance);
    });

    test('the defaults block nothing', () {
      expect(const ForceUpdatePolicy().evaluate(1), allowed);
    });
  });

  group('offline cache', () {
    test('a saved policy reads back unchanged', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const saved = ForceUpdatePolicy(
        minVersionCode: 30,
        latestVersionCode: 31,
        forceUpdate: true,
        updateMessage: 'Please update',
        playStoreUrl: 'https://play.google.com/store/apps/details?id=x',
        apkUrl: 'https://example.com/app.apk',
        maintenanceMode: false,
        maintenanceMessage: 'Back soon',
      );
      await saved.saveTo(prefs);

      final loaded = ForceUpdatePolicy.fromPrefs(prefs);
      expect(loaded.minVersionCode, 30);
      expect(loaded.latestVersionCode, 31);
      expect(loaded.forceUpdate, isTrue);
      expect(loaded.updateMessage, 'Please update');
      expect(loaded.playStoreUrl, saved.playStoreUrl);
      expect(loaded.apkUrl, saved.apkUrl);
      expect(loaded.maintenanceMode, isFalse);
      expect(loaded.maintenanceMessage, 'Back soon');
      // The saved policy still blocks an outdated install offline.
      expect(loaded.evaluate(24), updateRequired);
    });

    test('nothing saved yet means nothing is blocked', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(ForceUpdatePolicy.fromPrefs(prefs).evaluate(24), allowed);
    });
  });
}
