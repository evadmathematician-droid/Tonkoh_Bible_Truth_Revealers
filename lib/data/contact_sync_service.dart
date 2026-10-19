import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'contacts_cache.dart';
import 'contacts_repository.dart';
import 'display_names.dart';

/// Keeps the contact book (and therefore every name in the app — see
/// [DisplayNames]) in step with the phone's address book without the user
/// ever opening the Contacts screen:
///
///  * on launch, once signed in;
///  * right after the contacts permission is granted;
///  * when the app comes back to the foreground (debounced);
///  * when the phone's contacts change (a contact saved or renamed);
///  * on pull-to-refresh in the Contacts screen.
///
/// Matching happens on the device (ContactsRepository.fetchContactBook);
/// the address book itself is never uploaded.
class ContactSyncService with WidgetsBindingObserver {
  ContactSyncService._();
  static final ContactSyncService instance = ContactSyncService._();

  /// Foreground resumes within this window of the last sync don't rescan.
  static const Duration resumeDebounce = Duration(minutes: 5);

  // Asked once from here; afterwards only the Contacts screen re-asks.
  static const String _askedKey = 'contacts_perm_auto_asked_v1';

  bool _started = false;
  bool _listening = false;
  Future<void>? _running;
  bool _pending = false;
  Timer? _changeDebounce;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Safe to call more than once; only the first call does anything.
  Future<void> start() async {
    await DisplayNames.instance.load();
    await ContactsCache.instance.load();
    if (_started || !_supported) return;
    _started = true;

    WidgetsBinding.instance.addObserver(this);

    if (!await _ensurePermission()) return;
    _listen();
    unawaited(sync());
  }

  /// Call after the Contacts screen obtained the permission.
  Future<void> onPermissionGranted() async {
    _listen();
    await sync();
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    FlutterContacts.addListener(_onContactsChanged);
  }

  Future<bool> _ensurePermission() async {
    try {
      if (await Permission.contacts.isGranted) return true;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) == true) return false;
      await prefs.setBool(_askedKey, true);
      return (await Permission.contacts.request()).isGranted;
    } catch (e) {
      debugPrint('ContactSyncService: permission check failed: $e');
      return false;
    }
  }

  void _onContactsChanged() {
    // The provider fires several times for one edit — settle first.
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(seconds: 2), () => sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_onResumed());
  }

  Future<void> _onResumed() async {
    // Permission may have been granted from system settings since launch.
    if (!await Permission.contacts.isGranted) return;
    _listen();
    if (ContactsCache.instance.syncedWithin(resumeDebounce)) return;
    await sync();
  }

  /// Rescan now; completes when the scan (and any follow-up a concurrent
  /// call asked for) is done.
  Future<void> sync() {
    if (_running != null) {
      _pending = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    try {
      do {
        _pending = false;
        final cache = ContactsCache.instance;
        final book =
            await ContactsRepository.fetchContactBook(previous: cache.book);
        final stats = ContactsRepository.lastStats;
        // Every lookup failed (offline): keep what we already have rather
        // than showing everyone as "not on the app".
        final allFailed = stats.validNumbers > 0 &&
            stats.failedLookups == stats.validNumbers;
        if (allFailed && cache.hasLoadedOnce) break;
        cache.setBook(book, stats);
      } while (_pending);
    } catch (e) {
      debugPrint('ContactSyncService: sync failed: $e');
    }
  }
}
