import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../services/web_onesignal_bridge.dart'
if (dart.library.io) '../../services/web_onesignal_bridge_stub.dart';

import '../../data/profile_photo_cache.dart';
import '../../data/user_profile.dart';
import '../../util/phone_utils.dart';

/// Equivalent of AuthManager.kt (Kotlin `object` → Dart class with static
/// members, since this is a stateless singleton service, not a widget's
/// state).
class AuthManager {
  AuthManager._(); // prevent instantiation — mirrors Kotlin `object`

  static const int _maxPhotoBytes = 600000;
  static const String _prefsPrefix = "auth_cache_";

  static FirebaseAuth get _auth => FirebaseAuth.instance;
  static DatabaseReference get _usersRef =>
      FirebaseDatabase.instance.ref("users");

  // Guards against double-registering the OneSignal observer if
  // syncOneSignalPlayerId() gets called more than once (e.g. app resume).
  static bool _observerRegistered = false;

  // Session-scoped only (never persisted) — lets AdminScreen and
  // AdminAudioApprovalScreen share one PIN-unlock instead of each keeping
  // its own local flag, which is what previously let /adminApproval be
  // reached directly (e.g. by URL on web, or a deep link) with no PIN
  // check at all, since it never looked at AdminScreen's private State.
  static bool isAdminUnlockedThisSession = false;

  // SHA-256 of the admin PIN — NOT the PIN itself. Storing this instead of
  // the literal "2222" that used to sit here means decompiling the app no
  // longer hands over the PIN directly; an attacker only gets the hash and
  // has to brute-force it offline. For a 4-digit numeric PIN that's still
  // only 10,000 SHA-256 computations (milliseconds), so this remains a
  // convenience gate, not real access control — it does nothing to protect
  // the underlying Firebase writes from someone who skips the UI entirely
  // and calls the RTDB SDK directly. Real protection for those writes has
  // to come from Firebase RTDB security rules, which can't check a value
  // that only exists in the client.
  //
  // To rotate the PIN: compute the new hash and replace the constant below.
  //   node -e "console.log(require('crypto').createHash('sha256').update('NEWPIN').digest('hex'))"
  // This hash is sha256("2222") — the PIN already in use before this change.
  static const String _adminPinHash =
      'edee29f882543b956620b26d0ee0e7e950399b1c4222f5de05e06425b4c995e9';

  static bool isAdminPinCorrect(String pin) {
    final hash = sha256.convert(utf8.encode(pin)).toString();
    return hash == _adminPinHash;
  }

  /// Signs in anonymously if not already signed in. Mirrors ensureSignedIn.
  static Future<void> ensureSignedIn({
    required void Function() onReady,
    void Function(String message) onError = _noopError,
  }) async {
    if (_auth.currentUser != null) {
      onReady(
      );
      return;
    }
    try {
      final result = await _auth.signInAnonymously();
      if (result.user != null) {
        onReady();
      } else {
        onError("Sign-in succeeded but no user was returned");
      }
    } catch (e) {
      onError(e.toString());
    }
  }

  static Future<String?> currentUid() async {
    final profile = await getCachedProfile();
    return profile?.uid;
  }

  /// Reads the cached profile from SharedPreferences.
  /// NOTE: unlike Kotlin's synchronous SharedPreferences, Dart's
  /// shared_preferences is async — every call site that used
  /// AuthManager.currentUid(context) synchronously in Compose will need
  /// to become a FutureBuilder / await in a LaunchedEffect-equivalent
  /// when we port those screens.
  static Future<UserProfile?> getCachedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('${_prefsPrefix}uid');
    if (uid == null) return null;
    return UserProfile(
      uid: uid,
      name: prefs.getString('${_prefsPrefix}name') ?? '',
      phone: prefs.getString('${_prefsPrefix}phone') ?? '',
      country: prefs.getString('${_prefsPrefix}country') ?? '',
      photoUrl: prefs.getString('${_prefsPrefix}photoUrl') ?? '',
      createdAt: prefs.getInt('${_prefsPrefix}createdAt') ?? 0,
    );
  }

  static Future<void> _cacheProfileLocally(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefsPrefix}uid', profile.uid);
    await prefs.setString('${_prefsPrefix}name', profile.name);
    await prefs.setString('${_prefsPrefix}phone', profile.phone);
    await prefs.setString('${_prefsPrefix}country', profile.country);
    await prefs.setString('${_prefsPrefix}photoUrl', profile.photoUrl);
    await prefs.setInt('${_prefsPrefix}createdAt', profile.createdAt);
  }

  static Future<void> _clearCachedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      'uid', 'name', 'phone', 'country', 'photoUrl', 'createdAt'
    ]) {
      await prefs.remove('$_prefsPrefix$key');
    }
  }

  static Future<UserProfile?> fetchProfile({
    required String phoneKey,
    void Function(String message) onError = _noopError,
  }) async {
    try {
      final snapshot = await _usersRef.child(phoneKey).get();
      if (!snapshot.exists) return null;
      final profile = UserProfile.fromMap(
        Map<dynamic, dynamic>.from(snapshot.value as Map),
      );
      await _cacheProfileLocally(profile);
      return profile;
    } catch (e) {
      onError(e.toString());
      return null;
    }
  }

  static Future<String> _encodeCroppedPhotoToBase64(String photoPath) async {
    final file = File(photoPath);
    if (!await file.exists()) {
      throw StateError('Cropped photo file does not exist: $photoPath');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxPhotoBytes) {
      throw StateError(
        'Cropped photo is ${bytes.length ~/ 1024}KB, over the ${_maxPhotoBytes ~/ 1024}KB limit',
      );
    }
    return base64Encode(bytes);
  }

  /// Mirrors saveProfile(): shares the SAME normalizePhone() path used
  /// elsewhere in the app — see the ⚠️ stub warning in phone_utils.dart.
  static Future<void> saveProfile({
    required String name,
    required String phone,
    required String countryIso,
    String? newPhotoBase64,
    required void Function() onSuccess,
    void Function(String message) onError = _noopError,
  }) async {
    final e164Phone = normalizePhone(phone.trim(), countryIso);
    if (e164Phone == null) {
      onError("That doesn't look like a valid phone number");
      return;
    }

    try {
      final snapshot = await _usersRef.child(e164Phone).get();
      UserProfile? existing;
      if (snapshot.exists) {
        existing = UserProfile.fromMap(
          Map<dynamic, dynamic>.from(snapshot.value as Map),
        );
      }

      final finalPhotoUrl = newPhotoBase64 ?? existing?.photoUrl ?? '';
      final finalCreatedAt =
          existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch;

      final profile = UserProfile(
        uid: e164Phone,
        name: name.trim(),
        phone: e164Phone,
        country: countryIso,
        photoUrl: finalPhotoUrl,
        createdAt: finalCreatedAt,
      );

      await _usersRef.child(e164Phone).set(profile.toMap());
      await _cacheProfileLocally(profile);

      // Push the fresh photo into the app-wide cache immediately so every
      // CachedProfileAvatar for this uid (contact rows, chat list, chat
      // header) updates without waiting for their own next fetch —
      // ProfilePhotoCache's own doc comment names this exact call site.
      ProfilePhotoCache.instance.updateCached(e164Phone, finalPhotoUrl);

      // Best-effort immediate write. This is NOT the only place the
      // OneSignal ID gets saved anymore — see syncOneSignalPlayerId()
      // below, which is the reliable path and should be called on every
      // app startup regardless of whether the profile was just edited.
      final playerId = OneSignal.User.pushSubscription.id;
      if (playerId != null) {
        await _usersRef.child(e164Phone).child('oneSignalId').set(playerId);
      }

      onSuccess();
    } catch (e) {
      onError(e.toString());
    }
  }

  static Future<void> saveProfileWithPhoto({
    required String name,
    required String phone,
    required String countryIso,
    String? newPhotoPath,
    required void Function() onSuccess,
    void Function(String message) onError = _noopError,
  }) async {
    String? newPhotoBase64;
    if (newPhotoPath != null) {
      try {
        newPhotoBase64 = await _encodeCroppedPhotoToBase64(newPhotoPath);
      } catch (e) {
        onError(e.toString());
        return;
      }
    }

    await saveProfile(
      name: name,
      phone: phone,
      countryIso: countryIso,
      newPhotoBase64: newPhotoBase64,
      onSuccess: onSuccess,
      onError: onError,
    );
  }

  /// Reliable OneSignal player-ID sync.
  ///
  /// Call this once on every app startup, AFTER ensureSignedIn() /
  /// getCachedProfile() has resolved a user. It fixes a race condition in
  /// saveProfile(): OneSignal.User.pushSubscription.id is frequently still
  /// null at the moment a fresh signup calls saveProfile(), because
  /// OneSignal hasn't finished registering the device with its backend
  /// yet. When that happens the old code silently skipped the write and
  /// NEVER retried — so that device could never receive call/chat push
  /// notifications until the user happened to edit their profile again.
  ///
  /// This method:
  /// 1. Writes the ID immediately if it's already available.
  /// 2. Registers an observer that catches the ID the moment OneSignal
  ///    assigns/changes it, and writes it then too — covering the case
  ///    where it's still null right now.
  ///
  /// On web, OneSignal's Flutter plugin doesn't expose pushSubscription
  /// the same way, so this delegates to a JS bridge (web_onesignal_bridge.dart)
  /// that talks to the OneSignal Web SDK loaded in web/index.html.
  static Future<void> syncOneSignalPlayerId() async {
    final profile = await getCachedProfile();
    if (profile == null || profile.uid.isEmpty) return;

    final uid = profile.uid;

    if (kIsWeb) {
      await WebOneSignalBridge.requestPermission();

      // Write immediately if we already have an ID.
      final currentId = await WebOneSignalBridge.getSubscriptionId();
      if (currentId != null) {
        await _usersRef.child(uid).child('oneSignalId').set(currentId);
      }

      // Also listen for it becoming available/changing, same as the
      // Android observer below.
      if (!_observerRegistered) {
        _observerRegistered = true;
        WebOneSignalBridge.onSubscriptionChange((id) async {
          final latestProfile = await getCachedProfile();
          if (latestProfile == null || latestProfile.uid.isEmpty) return;
          await _usersRef
              .child(latestProfile.uid)
              .child('oneSignalId')
              .set(id);
        });
      }
      return;
    }

    // --- existing Android/iOS path, untouched ---

    // Write immediately if we already have an ID.
    final currentId = OneSignal.User.pushSubscription.id;
    if (currentId != null) {
      await _usersRef.child(uid).child('oneSignalId').set(currentId);
    }

    // Also listen for it becoming available/changing, in case it's null
    // right now (typical right after a fresh install) or gets rotated
    // later (reinstall, OneSignal reset, etc).
    if (!_observerRegistered) {
      _observerRegistered = true;
      OneSignal.User.pushSubscription.addObserver((state) async {
        final id = state.current.id;
        if (id == null) return;
        // Re-resolve the current user each time in case they've switched
        // accounts since the observer was registered.
        final latestProfile = await getCachedProfile();
        if (latestProfile == null || latestProfile.uid.isEmpty) return;
        await _usersRef
            .child(latestProfile.uid)
            .child('oneSignalId')
            .set(id);
      });
    }
  }

  /// Clears the local session (cached profile + Firebase Auth) WITHOUT
  /// touching the backend account record. Use this for "unlink this
  /// device" — the account and its data on other devices are untouched,
  /// only this device's local session ends. deleteAccount() below builds
  /// on top of this for the "delete account entirely" case.
  static Future<void> signOut() async {
    await _clearCachedProfile();
    try {
      await _auth.signOut();
    } catch (_) {
      // Best-effort — a failed remote sign-out shouldn't block the local
      // session from ending; ensureSignedIn() will just re-authenticate
      // anonymously next launch if needed.
    }
  }

  static Future<void> deleteAccount({
    required String phoneKey,
    required void Function() onSuccess,
    void Function(String message) onError = _noopError,
  }) async {
    try {
      // users/{phoneKey}.remove() already cascades to delete
      // users/{phoneKey}/devices (linked devices) since RTDB deletes a
      // node's entire subtree — no separate devices cleanup needed.
      await _usersRef.child(phoneKey).remove();
      // userChats lives at a separate top-level path, so it needs its
      // own explicit cleanup — otherwise a deleted account's chat list
      // would silently survive the "delete" and could still surface
      // (e.g. to a re-registration under the same number later).
      await FirebaseDatabase.instance.ref('userChats').child(phoneKey).remove();
      await signOut();
      onSuccess();
    } catch (e) {
      onError(e.toString());
    }
  }

  static void _noopError(String _) {}
}