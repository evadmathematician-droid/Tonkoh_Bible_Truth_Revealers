import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';

/// Equivalent of ProfilePhotoCache.kt — app-wide singleton, same pattern
/// as ContactsCache/GlobalAudioPlayer. Caches each uid's Base64 photoUrl
/// in memory so repeated lookups across screens are instant instead of
/// re-querying Firebase every time an avatar renders.
///
/// ⚠️ See the note above this file in chat: the Kotlin call site reads
/// synchronously, which this can't fully replicate on a cold cache.
/// photoFor() returns null immediately for an unseen uid and triggers a
/// background fetch; listen via ChangeNotifier (CachedProfileAvatar does
/// this) to pick up the photo once it arrives.
class ProfilePhotoCache extends ChangeNotifier {
  ProfilePhotoCache._internal();
  static final ProfilePhotoCache instance = ProfilePhotoCache._internal();

  final Map<String, String> _cache = {};
  final Set<String> _inFlight = {};

  /// Synchronous read of whatever's cached right now. Returns null if
  /// nothing's cached yet (or the user has no photo set) — kicks off a
  /// background fetch as a side effect so a later call/notify picks it up.
  String? photoFor(String uid) {
    if (uid.isEmpty) return null;

    final cached = _cache[uid];
    if (cached != null) return cached;

    if (!_inFlight.contains(uid)) {
      _fetch(uid);
    }
    return null;
  }

  Future<void> _fetch(String uid) async {
    _inFlight.add(uid);
    try {
      final snapshot = await FirebaseDatabase.instance.ref('users').child(uid).child('photoUrl').get();
      final value = snapshot.value;
      if (value is String && value.isNotEmpty) {
        _cache[uid] = value;
        notifyListeners();
      }
    } catch (_) {
      // Offline or no network — leave uncached; next photoFor() call
      // will retry naturally since we only skip re-fetching while
      // _inFlight, not permanently.
    } finally {
      _inFlight.remove(uid);
    }
  }

  /// Call after a profile save (e.g. from the settings/edit-profile
  /// screen) so every other screen's avatar for this uid updates
  /// immediately instead of waiting for a fresh fetch.
  void updateCached(String uid, String photoUrl) {
    _cache[uid] = photoUrl;
    notifyListeners();
  }

  void clear() {
    _cache.clear();
    notifyListeners();
  }
}