import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../data/account_self_repair.dart';
import '../data/chat_sync_service.dart';
import '../data/contact_sync_service.dart';
import '../data/phone_aliases.dart';
import '../data/profile_photo_cache.dart';
import '../data/profile_settings_repository.dart';
import '../screens/auth/auth_manager.dart';
import '../share/share_intake.dart';
import '../screens/profile/profile_setup_screen.dart';
import '../permissions/permissions_onboarding.dart';
import '../calls/call_signaling_repository.dart';
import '../calls/incoming_call_manager.dart';
import '../calls/nativecallbridge.dart';
import '../calls/platform_call_support.dart';
import 'app_router.dart';

/// Equivalent of the sealed AuthGateState in AppNavigation.kt.
enum _GateStatus { loading, needsProfile, ready }

class AuthGate extends StatefulWidget {
  final String? startChatUid;
  const AuthGate({super.key, this.startChatUid});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  _GateStatus _status = _GateStatus.loading;
  String? _uid;
  StreamSubscription<DatabaseEvent>? _profileSub;
  final CallSignalingRepository _callSignalingRepo = CallSignalingRepository();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Mirrors: try the local cache first (was synchronous in Kotlin,
    // here it's the first await instead of a `remember` initializer).
    final cached = await AuthManager.getCachedProfile();
    if (cached != null) {
      _setReady(cached.uid);
    } else if (mounted) {
      // No account on this phone: show registration right away instead of
      // a spinner while anonymous sign-in waits for the network (it
      // continues below; Continue waits for it if needed).
      setState(() => _status = _GateStatus.needsProfile);
    }

    // Mirrors ensureSignedIn(...) in the Kotlin LaunchedEffect(Unit).
    await AuthManager.ensureSignedIn(
      onReady: () async {
        // If the cache already resolved us to Ready above, don't
        // second-guess it — same guard as the Kotlin version.
        if (_status == _GateStatus.ready) {
          unawaited(ContactSyncService.instance.start());
          return;
        }
        final cached2 = await AuthManager.getCachedProfile();
        if (!mounted) return;
        if (cached2 != null) {
          _setReady(cached2.uid);
          unawaited(ContactSyncService.instance.start());
        } else {
          setState(() => _status = _GateStatus.needsProfile);
        }
      },
      onError: (_) {}, // matches Kotlin's empty onError
    );

    // Signed in now: fix this device's own account id if an older version
    // saved it malformed — first with the alias table saved on the phone,
    // then again if the background refresh brings a new one. Nothing here
    // is awaited by the UI, so a slow or missing connection never delays
    // a screen.
    unawaited(() async {
      await PhoneAliases.instance.loadCached();
      await _repairAccountId();
      if (await PhoneAliases.instance.refresh()) await _repairAccountId();
    }());
  }

  /// Re-points this device at its corrected account id, if it has one.
  /// Returns true when the gate switched to it.
  Future<bool> _repairAccountId() async {
    final fixed = await AccountSelfRepair.run();
    if (fixed == null || !mounted) return false;
    _setReady(fixed);
    return true;
  }

  void _setReady(String uid) {
    final alreadyReadyForThisUser =
        _uid == uid && _status == _GateStatus.ready;
    _uid = uid;
    setState(() => _status = _GateStatus.ready);
    _watchProfileExistence(uid);
    // Local-first chats: saved avatars into memory, and new messages saved
    // to the phone in the background before any chat is opened.
    unawaited(ProfilePhotoCache.instance.warmUp());
    unawaited(ChatSyncService.instance.start(uid));
    // A Settings edit saved offline goes out when the connection returns.
    ProfileSettingsRepository.instance.startAutoSync();
    // Anything shared in from another app while signed out can open now.
    ShareIntake.instance.onSignedIn();

    // FIX (web/desktop/iOS showed no incoming-call UI at all): the incoming-call
    // RTDB listener was only ever wired up in lib/screens/auth/auth_gate.dart,
    // an orphaned migration-era duplicate that main.dart never imports. main.dart
    // renders THIS gate, which never started the listener, so
    // CallSignalingRepository's `calls` query never attached and a call placed
    // from another device produced no ring and no debug output on the callee.
    // Start it here now, once we know the user's uid. It's a hard no-op on
    // Android (callsHandledNatively) — the native Telecom/OneSignal stack owns
    // incoming calls there and running this too is the old double-ring bug.
    if (!alreadyReadyForThisUser) {
      _startIncomingCallListener(uid);
      // Also pick up an incoming call that arrived while the app was
      // killed / backgrounded — the native full-screen notification
      // launched us with call extras; NativeCallBridge turns them into the
      // same IncomingCallManager flow. Safe to call repeatedly (guarded).
      NativeCallBridge.init();
    }
  }

  void _startIncomingCallListener(String uid) {
    if (callsHandledNatively) {
      debugPrint('AuthGate: native call stack owns incoming calls — '
          'skipping Flutter incoming-call listener');
      return;
    }

    // Don't stack multiple listeners if _setReady runs again for a new uid.
    _callSignalingRepo.stopListeningForIncomingCalls();

    debugPrint('AuthGate: 🎧 attaching incoming-call listener for uid=$uid');

    _callSignalingRepo.startListeningForIncomingCalls(
      uid,
      (callId, callerUid, callerName, callerPhoto, chatId, type) {
        IncomingCallManager.instance.handleIncomingCall(
          callId: callId,
          callerId: callerUid,
          callerName: callerName,
          callerPhoto: callerPhoto,
          chatId: chatId,
          callType: type,
        );
      },
    );
  }

  /// Mirrors the DisposableEffect(readyUid) ValueEventListener: if the
  /// user's Firebase profile ever disappears while Ready, drop back to
  /// NeedsProfile.
  ///
  /// Also enforces "one active device": if the account's `activeDeviceId`
  /// changes to something other than this install's id — which is what an
  /// account migration to another device does — this device's session is
  /// no longer valid, so drop its cached profile and send it back to
  /// registration.
  void _watchProfileExistence(String uid) {
    _profileSub?.cancel();
    final ref = FirebaseDatabase.instance.ref('users').child(uid);
    _profileSub = ref.onValue.listen((event) async {
      if (!mounted) return;
      if (!event.snapshot.exists) {
        // The record may have moved to its corrected E.164 key (data
        // repair) rather than been deleted — follow it if so.
        if (await _repairAccountId()) return;
        if (mounted) setState(() => _status = _GateStatus.needsProfile);
        return;
      }

      final eventId = event.snapshot.child('activeDeviceId').value as String?;
      if (eventId == null || eventId.isEmpty) return;

      final myDeviceId = await AuthManager.deviceId();
      if (eventId == myDeviceId) {
        // Firebase agrees this is the active device — stop second-guessing.
        await AuthManager.clearClaimMarker();
        unawaited(AuthManager.linkAuthUid(uid));
        return;
      }

      // The passive `onValue` emission can carry a STALE cached value — right
      // after a migration, RTDB persistence replays the previous owner's
      // activeDeviceId for a moment before syncing the Worker's PATCH. So
      // before signing this device out, confirm with a direct server read
      // and honour a fresh local "I just claimed this account" marker.
      String? serverId;
      try {
        final snap = await ref.child('activeDeviceId').get();
        serverId = snap.value as String?;
      } catch (_) {}
      final recentlyClaimed =
          await AuthManager.recentlyClaimedByThisDevice(uid);

      debugPrint('[DeviceWatch] uid=$uid  event=$eventId  server=$serverId  '
          'mine=$myDeviceId  recentlyClaimed=$recentlyClaimed');

      final effective = serverId ?? eventId;
      if (effective == myDeviceId) {
        await AuthManager.clearClaimMarker();
        unawaited(AuthManager.linkAuthUid(uid));
        return; // stale cache — we are still the active device
      }
      if (recentlyClaimed) {
        // We took ownership seconds ago; the server read hasn't caught up
        // (or failed). Don't sign ourselves out — a later event, or the
        // grace window expiring, will settle it.
        return;
      }

      // This device has been migrated away from this account — sign out.
      debugPrint('[DeviceWatch] signing out uid=$uid — active device is now $effective');
      await _profileSub?.cancel();
      _profileSub = null;
      await ChatSyncService.instance.stop();
      await AuthManager.clearCachedProfile();
      if (mounted) setState(() => _status = _GateStatus.needsProfile);
    });
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _callSignalingRepo.stopListeningForIncomingCalls();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _GateStatus.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );

      case _GateStatus.needsProfile:
        return ProfileSetupScreen(
          onDone: () async {
            final cached = await AuthManager.getCachedProfile();
            if (!mounted) return;
            if (cached != null) {
              _setReady(cached.uid);
              // Registration just completed — this is the only code path
              // that reaches here (a normal launch with a cached profile
              // goes through _bootstrap). Fire the upfront
              // Phone → Camera → Microphone → ignore-battery-optimization
              // prompts as the user lands on the home screen. Not awaited:
              // denial must never block navigation, and the helper is a
              // no-op after the first run.
              // Contact sync asks for its own permission, so start it only
              // once these dialogs are done (two permission requests at
              // once fail).
              PermissionsOnboarding.maybeRunAfterRegistration().whenComplete(
                  () => ContactSyncService.instance.start());
            } else {
              setState(() => _status = _GateStatus.needsProfile);
            }
          },
        );

      case _GateStatus.ready:
        return MainNavHost(startChatUid: widget.startChatUid);
    }
  }
}