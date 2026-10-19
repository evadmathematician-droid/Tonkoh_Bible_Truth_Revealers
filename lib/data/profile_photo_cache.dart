import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';

import 'local_chat_store.dart';

/// App-wide cache of each user's Base64 profile photo, keyed by account id.
///
/// Photos are kept in memory AND saved on the phone (LocalChatStore's
/// `profile_photos` table), so avatars in chats, the chat list and the
/// contact list appear instantly on the first frame — also offline — and
/// are refreshed from Firebase in the background once per session.
///
/// photoFor() never waits: it returns what is known now (possibly null)
/// and fetches in the background; listen via ChangeNotifier
/// (CachedProfileAvatar does this) to pick up a newer photo.
class ProfilePhotoCache extends ChangeNotifier {
  ProfilePhotoCache._internal();
  static final ProfilePhotoCache instance = ProfilePhotoCache._internal();

  final Map<String, String> _cache = {};
  final Set<String> _inFlight = {};
  // Refreshed from Firebase this session (saved copies may be stale).
  final Set<String> _fresh = {};
  Future<void>? _warming;

  /// Loads every saved photo into memory. Call once at startup.
  Future<void> warmUp() => _warming ??= () async {
        try {
          final saved = await LocalChatStore.instance.allPhotos();
          for (final e in saved.entries) {
            _cache.putIfAbsent(e.key, () => e.value);
          }
          if (saved.isNotEmpty) notifyListeners();
        } catch (e) {
          debugPrint('ProfilePhotoCache: warm-up failed: $e');
        }
      }();

  /// Synchronous read of whatever's cached right now (null if nothing yet,
  /// or the user has no photo). Kicks off a background refresh once per
  /// session.
  String? photoFor(String uid) {
    if (uid.isEmpty) return null;
    if (!_fresh.contains(uid) && !_inFlight.contains(uid)) _fetch(uid);
    return _cache[uid];
  }

  Future<void> _fetch(String uid) async {
    _inFlight.add(uid);
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref('users')
          .child(uid)
          .child('photoUrl')
          .get();
      _fresh.add(uid);
      final value = snapshot.value;
      if (value is String && value.isNotEmpty && value != _cache[uid]) {
        _cache[uid] = value;
        notifyListeners();
        await LocalChatStore.instance.savePhoto(uid, value);
      }
    } catch (_) {
      // Offline — keep the saved copy; the next photoFor() retries.
    } finally {
      _inFlight.remove(uid);
    }
  }

  /// Call after a profile save so every screen's avatar for this uid
  /// updates immediately instead of waiting for a fresh fetch.
  void updateCached(String uid, String photoUrl) {
    _cache[uid] = photoUrl;
    _fresh.add(uid);
    notifyListeners();
    if (photoUrl.isNotEmpty) LocalChatStore.instance.savePhoto(uid, photoUrl);
  }

  void clear() {
    _cache.clear();
    _fresh.clear();
    notifyListeners();
  }
}
