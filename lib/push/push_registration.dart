import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../navigation/app_router.dart';

/// Ties this install's push address to the signed-in account, and opens
/// the right chat when a message notification is tapped.
///
/// Pushes are addressed by OneSignal external ID = the account id
/// ([OneSignal.login] at sign-in, [OneSignal.logout] at sign-out). OneSignal
/// keeps that link on its servers, so pushes reach the phone after a
/// restart even if TBTR is never opened. `users/{uid}/oneSignalId` is still
/// saved: the Worker falls back to it for phones on older builds that never
/// logged in, and account migration uses it.
///
/// Before this, the id was saved only once, at registration, and only if
/// OneSignal already had one at that moment (often not, on a fresh
/// install). A reinstall or cleared data also changes it. Pushes then went
/// to a dead or empty id, so a closed app received no messages and no
/// calls. Now it is written on every sign-in / app start and whenever
/// OneSignal reports a new id.
class PushRegistration {
  PushRegistration._();

  static String? _uid;
  static String? _savedId;
  static bool _listening = false;

  static bool get _supported => !kIsWeb;

  /// Call once at startup, before `runApp`, so a notification that
  /// launched the app is handled.
  static void initNotificationHandling() {
    if (!_supported) return;
    OneSignal.Notifications.addClickListener((event) {
      final data = event.notification.additionalData ?? const {};
      final senderUid = data['senderUid'];
      final chatId = data['chatId'];
      if (senderUid is String && senderUid.isNotEmpty && chatId != null) {
        openPrivateChat(senderUid);
      }
    });
    // The chat on screen already shows the message; don't also notify.
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final senderUid = event.notification.additionalData?['senderUid'];
      if (senderUid != null && senderUid == openPrivateChatUid) {
        event.preventDefault();
      }
    });
  }

  /// The signed-in account; saves this install's push id for it.
  static void start(String uid) {
    if (!_supported) return;
    if (_uid != uid) _savedId = null;
    _uid = uid;
    unawaited(_login(uid));
    if (!_listening) {
      _listening = true;
      OneSignal.User.pushSubscription.addObserver((state) {
        final id = state.current.id;
        if (id != null) unawaited(_save(id));
      });
    }
    final id = OneSignal.User.pushSubscription.id;
    if (id != null) unawaited(_save(id));
  }

  /// Signed out (account moved to another phone, or deleted): this install
  /// stops receiving the account's pushes.
  static void stop() {
    _uid = null;
    _savedId = null;
    if (!_supported) return;
    unawaited(OneSignal.logout().catchError((Object e) {
      debugPrint('PushRegistration: OneSignal logout failed: $e');
    }));
  }

  static Future<void> _login(String uid) async {
    try {
      await OneSignal.login(uid);
    } catch (e) {
      // Retried on the next start.
      debugPrint('PushRegistration: OneSignal login failed: $e');
    }
  }

  static Future<void> _save(String id) async {
    final uid = _uid;
    if (uid == null || id.isEmpty || id == _savedId) return;
    _savedId = id;
    try {
      // Queued by the database while offline; sent when back online.
      await FirebaseDatabase.instance.ref('users/$uid/oneSignalId').set(id);
      debugPrint('PushRegistration: push id saved for $uid');
    } catch (e) {
      // e.g. the account isn't linked to this login yet — try again on
      // the next start / id change.
      _savedId = null;
      debugPrint('PushRegistration: saving push id failed: $e');
    }
  }
}
