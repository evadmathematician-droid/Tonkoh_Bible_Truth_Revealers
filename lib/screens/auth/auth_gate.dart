import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../auth/auth_manager.dart';
import '../../permission_handler.dart'; // adjust path if yours differs
import '/navigation/app_router.dart';
import '/screens/profile/profile_setup_screen.dart';
import '/calls/call_signaling_repository.dart';
import '/calls/incoming_call_manager.dart';
import '/data/contacts_sync_service.dart';
import '/data/user_device_repository.dart';

enum _AuthPhase { loading, needsProfile, ready }

class AuthGate extends StatefulWidget {
  final String? startChatUid;
  const AuthGate({super.key, this.startChatUid});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  _AuthPhase _phase = _AuthPhase.loading;
  String? _uid;
  StreamSubscription<DatabaseEvent>? _userSub;
  final CallSignalingRepository _callSignalingRepo = CallSignalingRepository();
  final UserDeviceRepository _deviceRepo = UserDeviceRepository();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cached = await AuthManager.getCachedProfile();
    if (cached != null) {
      _setReady(cached.uid);
    }

    await AuthManager.ensureSignedIn(
      onReady: () async {
        if (_phase == _AuthPhase.ready) return;
        final cached = await AuthManager.getCachedProfile();
        if (cached != null) {
          _setReady(cached.uid);
        } else {
          if (mounted) setState(() => _phase = _AuthPhase.needsProfile);
        }
      },
      onError: (msg) {
        debugPrint('AuthGate: ensureSignedIn failed: $msg');
      },
    );
  }

  void _setReady(String uid) {
    final alreadyReadyForThisUser = _uid == uid && _phase == _AuthPhase.ready;
    _uid = uid;
    if (mounted) setState(() => _phase = _AuthPhase.ready);
    _watchProfileDeletion(uid);

    if (!alreadyReadyForThisUser) {
      _startIncomingCallListener(uid);
    }

    // Fire-and-forget, same as the incoming-call listener above: neither
    // should block MainNavHost from rendering. Runs on every resolved
    // sign-in (cold start, and again if the uid actually changes), not
    // just first-ever launch — matching "on app launch" for the contacts
    // sync, and keeping the linked-devices list's lastActiveAt honest.
    ContactsSyncService.sync(uid);
    _registerDeviceAndCheckLinkStatus(uid);
  }

  /// If this device was unlinked from Settings (on this device or another
  /// one), registerCurrentDevice reports that instead of silently
  /// re-adding it — see UserDeviceRepository's doc. Treat that as a
  /// forced sign-out: the account itself is untouched, only this
  /// session ends, same as AuthManager.signOut()'s contract.
  Future<void> _registerDeviceAndCheckLinkStatus(String uid) async {
    final result = await _deviceRepo.registerCurrentDevice(uid);
    if (result == DeviceRegistrationResult.unlinkedRemotely && mounted) {
      await AuthManager.signOut();
      _setNeedsProfile();
    }
  }

  void _setNeedsProfile() {
    _userSub?.cancel();
    _callSignalingRepo.stopListeningForIncomingCalls();
    if (mounted) setState(() => _phase = _AuthPhase.needsProfile);
  }

  void _startIncomingCallListener(String uid) {
    // Make sure we don't stack multiple listeners if _setReady runs again.
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

  void _watchProfileDeletion(String uid) {
    _userSub?.cancel();
    final ref = FirebaseDatabase.instance.ref('users').child(uid);
    _userSub = ref.onValue.listen((event) {
      if (!event.snapshot.exists && mounted) {
        setState(() => _phase = _AuthPhase.needsProfile);
      }
    });
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _callSignalingRepo.stopListeningForIncomingCalls();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _AuthPhase.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case _AuthPhase.needsProfile:
        return ProfileSetupScreen(
          onDone: () async {
            // Request camera/mic/phone/notifications/bluetooth right after
            // registration completes — matches native app's post-signup flow.
            await CorePermissions.requestAfterRegistration();

            final cached = await AuthManager.getCachedProfile();
            if (cached != null) {
              _setReady(cached.uid);
            } else if (mounted) {
              setState(() => _phase = _AuthPhase.needsProfile);
            }
          },
        );
      case _AuthPhase.ready:
        return MainNavHost(startChatUid: widget.startChatUid);
    }
  }
}