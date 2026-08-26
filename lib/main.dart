import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:provider/provider.dart';

import 'screens/app_update_gate.dart';
import 'firebase_options.dart';
import 'screens/audio/audio_feed_provider.dart';
import 'screens/audio/global_audio_player.dart';
import 'screens/auth/auth_manager.dart';

import 'calls/call_foreground_service.dart';
import 'calls/call_notifications.dart';
import 'calls/incoming_call_manager.dart';
import 'calls/ongoing_call_manager.dart';
import 'navigation/call_navigator.dart';

const String oneSignalAppId = "371c8ad4-ea1c-4308-bc45-cfab712b9670";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Must run before GlobalAudioPlayer.instance is first touched (that
  // happens when TBTRApp's MultiProvider builds below, via runApp) —
  // this is what makes a play/pause + progress-bar notification appear
  // for the audio player while the app is backgrounded. Previously
  // nothing did this at all.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.tbtrapp.audio.channel',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
  );

  // ── Call system init ──
  // Must complete BEFORE the OneSignal listeners below are registered:
  // addForegroundWillDisplayListener can fire and call
  // IncomingCallManager.handleIncomingCall -> CallNotifications.showIncomingCall
  // the instant a call push arrives, and flutter_local_notifications throws
  // if show() is called before initialize() finishes. Previously this ran
  // after the listeners were wired up, leaving a cold-start race window
  // where an incoming call could silently fail to ring.
  await CallNotifications.init();

  // Keeps the process alive for the duration of an active call via a
  // standard Android foreground service — the same mechanism WhatsApp/
  // Signal/etc. use for reliable background survival. Unlike requesting
  // battery-optimization exemption, this needs no "Allow" system dialog:
  // FOREGROUND_SERVICE is a normal permission granted automatically at
  // install time. Started/stopped per-call from OngoingCallManager.
  CallForegroundService.init();

  if (!kIsWeb) {
    OneSignal.initialize(oneSignalAppId);
    OneSignal.Notifications.requestPermission(true);

    // Reliable OneSignal → Firebase player-ID sync. Safe to call here even
    // if AuthGate also calls ensureSignedIn later — ensureSignedIn just
    // returns immediately if a user is already signed in. This fixes the
    // race where OneSignal.User.pushSubscription.id was still null at
    // profile-save time, so the ID never made it into Firebase and this
    // device silently never received call/chat push notifications.
    AuthManager.ensureSignedIn(
      onReady: () async {
        await AuthManager.syncOneSignalPlayerId();
      },
      onError: (msg) => debugPrint('main: OneSignal sync sign-in failed: $msg'),
    );

    // ── NEW: catch incoming_call pushes while the app is in the foreground ──
    // Without this, OneSignal falls back to its own default notification
    // display (silent, generic) instead of our custom full-screen ringing
    // UI in CallNotifications/IncomingCallManager.
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final data = event.notification.additionalData;
      if (data != null && data['type'] == 'incoming_call') {
        // Stop OneSignal from showing its own generic notification —
        // we're about to show our own full-screen ringing one instead.
        event.preventDefault();

        IncomingCallManager.instance.handleIncomingCall(
          callId: data['callId'] as String? ?? '',
          callerId: data['callerId'] as String? ?? '',
          callerName: data['callerName'] as String? ?? 'Unknown',
          callerPhoto: data['callerPhoto'] as String? ?? '',
          chatId: data['chatId'] as String? ?? '',
          callType: data['callType'] as String? ?? 'voice',
        );
      }
    });

    // Handles the case where OneSignal DID show its own notification
    // (e.g. background) and the user tapped it — brings them to the call.
    OneSignal.Notifications.addClickListener((event) {
      final data = event.notification.additionalData;
      if (data != null && data['type'] == 'incoming_call') {
        IncomingCallManager.instance.handleIncomingCall(
          callId: data['callId'] as String? ?? '',
          callerId: data['callerId'] as String? ?? '',
          callerName: data['callerName'] as String? ?? 'Unknown',
          callerPhoto: data['callerPhoto'] as String? ?? '',
          chatId: data['chatId'] as String? ?? '',
          callType: data['callType'] as String? ?? 'voice',
        );
      }
    });
  }

  // The foreground-service notification's own "End" button runs inside
  // that service's isolate, not this one — it can only reach us via this
  // data channel, unlike CallNotifications' actions below which fire
  // directly in the main isolate.
  FlutterForegroundTask.addTaskDataCallback((data) {
    if (data == 'end_call') {
      OngoingCallManager.instance.endCall();
    }
  });

  CallNotifications.actionStream.listen((action) {
    switch (action.action) {
      case 'open':
      // User tapped the notification BODY (not a specific button) —
      // bring them to the Accept/Decline screen without auto-accepting
      // or auto-declining anything.
      //
      // KNOWN GAP: CallNotificationAction doesn't currently carry
      // callerId/chatId (CallNotifications.showIncomingCall() is only
      // ever called with callId/callType/callerName upstream in
      // IncomingCallManager.handleIncomingCall()), but
      // CallNavigator.toIncomingCall() requires them. Falling back to
      // empty strings here so this compiles and the screen still opens
      // correctly off of callId — but if IncomingCallScreen actually
      // *displays or uses* callerId/chatId for anything beyond that,
      // thread them through CallNotifications' payload + showIncomingCall
      // signature + IncomingCallManager.handleIncomingCall as a follow-up.
        if (action.callId != null && action.callType != null) {
          CallNavigator.toIncomingCall(
            callId: action.callId!,
            callerId: '',
            callerName: action.callerName ?? 'Unknown',
            chatId: '',
            callType: action.callType!,
          );
        }
        break;
      case 'accept':
        IncomingCallManager.instance.acceptCall();
        if (action.callId != null && action.callType != null) {
          CallNavigator.toOngoingCall(
            callId: action.callId!,
            callType: action.callType!,
            isCaller: false,
            peerName: action.callerName ?? 'Unknown',
          );
        }
        break;
      case 'decline':
        IncomingCallManager.instance.declineCall();
        break;
      // 'end' used to arrive here from CallNotifications.showOngoingCall's
      // own End button — that notification was replaced by the foreground
      // service's (see the addTaskDataCallback above), so this case is now
      // unreachable and was removed.
    }
  });
  // ──────────────────────

  runApp(const TBTRApp());
}

class TBTRApp extends StatelessWidget {
  const TBTRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AudioFeedProvider()..init()),
        ChangeNotifierProvider.value(value: GlobalAudioPlayer.instance),
      ],
      child: MaterialApp(
        navigatorKey: CallNavigator.key, // ← required for background navigation
        title: 'Tonkoh Bible Truth Revealers',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF102A72),
          useMaterial3: true,
        ),
        home: const AppUpdateGate(),
      ),
    );
  }
}