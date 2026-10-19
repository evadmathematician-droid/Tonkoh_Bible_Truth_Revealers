import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../config/worker_api.dart';
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

  // SHA-256 of the admin PIN, not the PIN itself — see AuthManager.kt's
  // ADMIN_PIN_SHA256 comment for the same caveat (still brute-forceable
  // offline for a short numeric PIN; this only stops someone from reading
  // the PIN directly out of a decompiled/inspected build).
  static const String _adminPinSha256 =
      "edee29f882543b956620b26d0ee0e7e950399b1c4222f5de05e06425b4c995e9";

  static FirebaseAuth get _auth => FirebaseAuth.instance;
  static DatabaseReference get _usersRef =>
      FirebaseDatabase.instance.ref("users");

  static bool isAdminPinCorrect(String pin) =>
      sha256.convert(utf8.encode(pin)).toString() == _adminPinSha256;

  static const String _deviceIdKey = "device_identity_id";

  // Marker written when THIS device takes ownership of an account (fresh
  // registration or a successful migration). The auth-gate device-ownership
  // watcher consults it so it doesn't sign this device out on a stale RTDB
  // cache emission that still carries the *previous* owner's activeDeviceId
  // for a moment right after the migration PATCH.
  static const String _claimUidKey = "device_claim_uid";
  static const String _claimDeviceKey = "device_claim_device";
  static const String _claimTsKey = "device_claim_ts";
  static const Duration _claimGrace = Duration(minutes: 2);

  /// Mirrors AuthManager.kt's deviceId(): a random id generated once per
  /// install and persisted locally, distinguishing "this device" from any
  /// other device that might register the same phone number.
  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null) return existing;

    final fresh = const Uuid().v4();
    await prefs.setString(_deviceIdKey, fresh);
    return fresh;
  }

  /// Record that this device just became the active device for [uid].
  static Future<void> markThisDeviceClaimed(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_claimUidKey, uid);
    await prefs.setString(_claimDeviceKey, await deviceId());
    await prefs.setInt(
        _claimTsKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// True if this install claimed [uid] within the last [_claimGrace] — used
  /// to suppress a spurious sign-out while the RTDB cache catches up to the
  /// migration write.
  static Future<bool> recentlyClaimedByThisDevice(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_claimUidKey) != uid) return false;
    if (prefs.getString(_claimDeviceKey) != await deviceId()) return false;
    final ts = prefs.getInt(_claimTsKey) ?? 0;
    return DateTime.now().millisecondsSinceEpoch - ts <
        _claimGrace.inMilliseconds;
  }

  /// Drop the claim marker — call once Firebase has confirmed this device is
  /// the active one, so the watcher stops re-checking on every event.
  static Future<void> clearClaimMarker() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [_claimUidKey, _claimDeviceKey, _claimTsKey]) {
      await prefs.remove(k);
    }
  }

  /// Signs in anonymously if not already signed in. Mirrors ensureSignedIn.
  static Future<void> ensureSignedIn({
    required void Function() onReady,
    void Function(String message) onError = _noopError,
  }) async {
    if (_auth.currentUser != null) {
      onReady();
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

  // ── Auth link (users/{phone}/authUid ⇄ authIndex/{authUid}) ─────────────
  // Accounts are keyed by phone number but signed in anonymously, so the
  // database rules can't tell who owns users/{phone} from auth.uid alone.
  // The owner's auth uid is stored on the record and indexed back to the
  // phone; database.rules.json checks both directions.

  static bool _authLinkChecked = false;

  static Future<void> _writeAuthIndex(String phone) async {
    final authUid = _auth.currentUser?.uid;
    if (authUid == null) return;
    try {
      await FirebaseDatabase.instance.ref('authIndex/$authUid').set(phone);
    } catch (e) {
      debugPrint('AuthManager: authIndex write failed: $e');
    }
  }

  /// Fills in users/{phone}/authUid for records saved before the field
  /// existed (or reset by an account migration), and keeps the authIndex
  /// entry present. Call once this device is confirmed as the account's
  /// active device. Best-effort and runs once per launch.
  static Future<void> linkAuthUid(String phone) async {
    if (_authLinkChecked) return;
    final authUid = _auth.currentUser?.uid;
    if (authUid == null || phone.isEmpty) return;
    _authLinkChecked = true;
    try {
      final ref = _usersRef.child(phone).child('authUid');
      final current = (await ref.get()).value as String?;
      if (current == null || current.isEmpty) {
        await ref.set(authUid);
      } else if (current != authUid) {
        // Owned by another login (e.g. app data restored onto a new
        // install). Only an account migration can move it.
        debugPrint('AuthManager: account $phone is linked to another login');
        return;
      }
      await _writeAuthIndex(phone);
    } catch (e) {
      _authLinkChecked = false;
      debugPrint('AuthManager: linkAuthUid failed: $e');
    }
  }

  /// Server-side admin check: admins/{phone} == true. The PIN on the admin
  /// screen is only a second step; the database rules enforce this list.
  static Future<bool> isServerAdmin() async {
    final profile = await getCachedProfile();
    if (profile == null || profile.uid.isEmpty) return false;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('admins/${profile.uid}').get();
      return snap.value == true;
    } catch (e) {
      debugPrint('AuthManager: admin check failed: $e');
      return false;
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
    if (uid == null) return lastKnownProfile = null;
    return lastKnownProfile = UserProfile(
      uid: uid,
      name: prefs.getString('${_prefsPrefix}name') ?? '',
      phone: prefs.getString('${_prefsPrefix}phone') ?? '',
      country: prefs.getString('${_prefsPrefix}country') ?? '',
      photoUrl: prefs.getString('${_prefsPrefix}photoUrl') ?? '',
      createdAt: prefs.getInt('${_prefsPrefix}createdAt') ?? 0,
    );
  }

  /// The cached profile as of the last [getCachedProfile] (AuthGate reads
  /// it at startup) — synchronous, so a chat screen can pick its chat id
  /// and draw saved messages on its very first frame.
  static UserProfile? lastKnownProfile;

  static Future<void> _cacheProfileLocally(UserProfile profile) async {
    lastKnownProfile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefsPrefix}uid', profile.uid);
    await prefs.setString('${_prefsPrefix}name', profile.name);
    await prefs.setString('${_prefsPrefix}phone', profile.phone);
    await prefs.setString('${_prefsPrefix}country', profile.country);
    await prefs.setString('${_prefsPrefix}photoUrl', profile.photoUrl);
    await prefs.setInt('${_prefsPrefix}createdAt', profile.createdAt);
  }

  /// Re-points this device's cached account at [e164] after the account
  /// was moved from a malformed key (see AccountSelfRepair).
  static Future<void> adoptRepairedAccountId(String e164) async {
    final cached = await getCachedProfile();
    if (cached == null) return;
    await _cacheProfileLocally(UserProfile(
      uid: e164,
      name: cached.name,
      phone: e164,
      country: countryOfPhone(e164) ?? cached.country,
      photoUrl: cached.photoUrl,
      createdAt: cached.createdAt,
    ));
    _authLinkChecked = false;
  }

  static Future<void> clearCachedProfile() async {
    lastKnownProfile = null;
    await clearClaimMarker();
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

  /// Saves the profile under the strict E.164 form of [phone] — the one
  /// normalizePhone() used everywhere else; [countryIso] is the default
  /// country for a number typed without a country code.
  static Future<void> saveProfile({
    required String name,
    required String phone,
    required String countryIso,
    String? newPhotoBase64,
    required void Function() onSuccess,
    void Function(String message) onError = _noopError,
    // Fired instead of [onError] when the number is already claimed by
    // another device — lets the registration screen offer the migration
    // flow rather than dead-ending. Gets the normalised E.164.
    void Function(String e164Phone)? onAlreadyRegistered,
  }) async {
    final e164Phone = normalizePhone(phone, defaultCountry: countryIso);
    if (e164Phone == null) {
      onError("That doesn't look like a valid phone number");
      return;
    }
    // The number's own country, not just the picker's — they differ when
    // someone types a full +CC number.
    final country = countryOfPhone(e164Phone) ?? countryIso;

    try {
      final thisDeviceId = await deviceId();
      final snapshot = await _usersRef.child(e164Phone).get();
      UserProfile? existing;
      if (snapshot.exists) {
        existing = UserProfile.fromMap(
          Map<dynamic, dynamic>.from(snapshot.value as Map),
        );
      }

      // Duplicate-registration guard. The number is already claimed by a
      // DIFFERENT device — block this as a new-account attempt (possible
      // account takeover) and alert the current owner. Allowed through:
      //   * no existing record — a genuine first registration;
      //   * existing.activeDeviceId == this device — the same install
      //     re-saving its own profile (name/photo edit, re-open);
      //   * existing.activeDeviceId blank — a legacy record from before the
      //     field existed; let this device claim it.
      // A real second-device link would need its own flow, not this screen.
      if (existing != null &&
          existing.activeDeviceId.isNotEmpty &&
          existing.activeDeviceId != thisDeviceId) {
        unawaited(_alertOwnerOfRegistrationAttempt(e164Phone));
        if (onAlreadyRegistered != null) {
          onAlreadyRegistered(e164Phone);
        } else {
          onError(
              'This phone number has already been registered on another account.');
        }
        return;
      }

      final finalPhotoUrl = newPhotoBase64 ?? existing?.photoUrl ?? '';
      final finalCreatedAt =
          existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch;

      final profile = UserProfile(
        uid: e164Phone,
        name: name.trim(),
        phone: e164Phone,
        country: country,
        photoUrl: finalPhotoUrl,
        createdAt: finalCreatedAt,
        // Claims this phone number for THIS device — see deviceId() doc.
        activeDeviceId: thisDeviceId,
        authUid: _auth.currentUser?.uid ?? existing?.authUid ?? '',
      );

      await _usersRef.child(e164Phone).set(profile.toMap());
      await _writeAuthIndex(e164Phone);
      await _cacheProfileLocally(profile);
      await markThisDeviceClaimed(e164Phone);

      // Our own avatar is drawn from ProfilePhotoCache like everyone
      // else's, so refresh it now rather than showing the old photo until
      // the next fetch.
      ProfilePhotoCache.instance.updateCached(e164Phone, finalPhotoUrl);

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
    void Function(String e164Phone)? onAlreadyRegistered,
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
      onAlreadyRegistered: onAlreadyRegistered,
    );
  }

  static Future<void> deleteAccount({
    required String phoneKey,
    required void Function() onSuccess,
    void Function(String message) onError = _noopError,
  }) async {
    try {
      await _usersRef.child(phoneKey).remove();
      final authUid = _auth.currentUser?.uid;
      if (authUid != null) {
        await FirebaseDatabase.instance.ref('authIndex/$authUid').remove();
      }
      await clearCachedProfile();
      onSuccess();
    } catch (e) {
      onError(e.toString());
    }
  }

  // Same Cloudflare Worker relay the call/chat pushes use — keeps the
  // OneSignal REST key server-side. See private_chat_push.dart.
  /// Best-effort security alert to the device(s) currently registered to
  /// [phoneKey] when someone tries to register that number as a new
  /// account elsewhere.
  static Future<void> _alertOwnerOfRegistrationAttempt(String phoneKey) async {
    try {
      final snap = await _usersRef.child(phoneKey).child('oneSignalId').get();
      final playerId = snap.value as String?;
      if (playerId == null || playerId.isEmpty) return;

      await http.post(
        Uri.parse(WorkerApi.sendPushUrl),
        headers: await WorkerApi.headers(),
        body: jsonEncode({
          'secret': WorkerApi.legacySecret,
          'subscriptionIds': [playerId],
          'heading': 'Security alert',
          'content':
              "Someone tried to register your number on a new device. "
                  "If this wasn't you, please contact support.",
          'data': {'type': 'registration_attempt'},
        }),
      );
    } catch (_) {
      // A failed alert must not change the outcome — the registration is
      // still blocked regardless.
    }
  }

  static void _noopError(String _) {}
}