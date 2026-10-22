import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:provider/provider.dart';

import 'data/display_names.dart';
import 'data/local_feed_store.dart';
import 'screens/auth/auth_manager.dart';
import 'util/connection_status.dart';
import 'util/startup_trace.dart';
import 'widgets/offline_banner.dart';
import 'share/share_intake.dart';
import 'navigation/auth_gate.dart';
import 'firebase_options.dart';
import 'force_update/force_update_gate.dart';
import 'screens/audio/audio_feed_provider.dart';
import 'screens/audio/feed_audio_handler.dart';
import 'screens/audio/global_audio_player.dart';

import 'calls/call_notifications.dart';
import 'calls/incoming_call_manager.dart';
import 'calls/ongoing_call_manager.dart';
import 'navigation/call_navigator.dart';

const String oneSignalAppId = "371c8ad4-ea1c-4308-bc45-cfab712b9670";

Future<void> main() async {
  StartupTrace.mark('main');
  WidgetsFlutterBinding.ensureInitialized();

  // Read what the first screen needs from the phone right away, in
  // parallel with Firebase start-up: the saved feed and the signed-in
  // profile. Nothing on the way to the first frame waits for the network.
  if (!kIsWeb) unawaited(LocalFeedStore.instance.preload());
  final cachedProfile = AuthManager.getCachedProfile();

  // Smaller image memory (default 100 MB), freed in the background, so
  // Android is less likely to kill the app while it's not on screen.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 48 << 20
    ..maximumSize = 300;
  WidgetsBinding.instance.addObserver(_BackgroundMemoryTrim());

  if (!kIsWeb) {
    // Edge-to-edge (mandatory on Android 15+ / targetSdk 35+; this app
    // targets 36). Flutter already draws behind the system bars — this just
    // makes the bars themselves transparent instead of the OS painting a
    // scrim, and picks dark icons to suit the app's light surfaces. Every
    // screen keeps its content clear of the bars via SafeArea / the
    // Scaffold's own inset handling.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light, // iOS
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ));
  }

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  StartupTrace.mark('firebase');

  // Saved-contact names from the last contact sync, so the first frame
  // already shows the right names (the sync itself starts in AuthGate).
  await DisplayNames.instance.load();
  // The gate can open the app on its very first frame.
  await cachedProfile;
  StartupTrace.mark('displayNames+profile');

  // Media session for the audio-feed player — gives it an Android media
  // notification (title / artwork / play / pause / seek), lock-screen and
  // headset controls, and keeps playback alive when the app is backgrounded.
  // Must run before the first access to GlobalAudioPlayer.instance.
  if (!kIsWeb) {
    try {
      feedAudioHandler = await AudioService.init(
        builder: () => FeedAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.tbtrapp.audio.playback',
          androidNotificationChannelName: 'Audio playback',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (e) {
      debugPrint('main: AudioService.init failed: $e');
      feedAudioHandler = FeedAudioHandler();
    }
  } else {
    feedAudioHandler = FeedAudioHandler();
  }
  StartupTrace.mark('audioService');

  if (!kIsWeb) {
    // Offline-first: keep an on-disk cache of every RTDB path the app
    // listens to, and replay missed `onChildAdded` events from the last
    // synced point when connectivity returns. Must be set before any
    // database reference is used. (No web implementation. Throws on a dev
    // hot restart because the SDK is already running — harmless there.)
    try {
      FirebaseDatabase.instance.setPersistenceEnabled(true);
    } catch (e) {
      debugPrint('main: setPersistenceEnabled skipped: $e');
    }

    OneSignal.initialize(oneSignalAppId);
    OneSignal.Notifications.requestPermission(true);
  }

  // ── Call system init ──
  await CallNotifications.init();
  StartupTrace.mark('callNotifications');

  CallNotifications.actionStream.listen((action) {
    switch (action.action) {
      case 'accept':
        IncomingCallManager.instance.acceptCall();
        if (action.callType != null) {
          // Replace the ringing screen (not stack on top of it) so a later
          // hang-up returns to AuthGate rather than a stale incoming screen.
          CallNavigator.replaceWithOngoingCall(
            callId: action.callId,
            callType: action.callType!,
            isCaller: false,
            peerName: action.callerName ?? 'Unknown',
          );
        }
        break;
      case 'decline':
        IncomingCallManager.instance.declineCall();
        break;
      case 'end':
        OngoingCallManager.instance.endCall();
        break;
    }
  });
  // ──────────────────────

  // Content shared in from other apps ("Share → TBTR App"); held until
  // AuthGate reports a signed-in profile.
  unawaited(ShareIntake.instance.init());

  runApp(const TBTRApp());
  StartupTrace.mark('runApp');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    StartupTrace.markOnce('firstFrame');
    // Only a real outage shows the offline strip; checked after the first
    // frame so it never delays it.
    ConnectionStatus.instance.start();
  });
}

class TBTRApp extends StatelessWidget {
  const TBTRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AudioFeedProvider()..init()),
        ChangeNotifierProvider.value(value: GlobalAudioPlayer.instance),
        // Saved-contact names (or bare numbers) for every person shown.
        ChangeNotifierProvider.value(value: DisplayNames.instance),
      ],
      child: MaterialApp(
        navigatorKey: CallNavigator.key, // ← required for background navigation
        title: 'Tonkoh Bible Truth Revealers',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF102A72),
          useMaterial3: true,
        ),
        // Sits above the Navigator, so an outdated install can't reach any
        // screen — including call screens pushed from notifications.
        builder: (context, child) => ForceUpdateGate(
          logo: Image.asset('assets/icon/icon.png'),
          child: OfflineBanner(child: child!),
        ),
        home: const AuthGate(),
      ),
    );
  }
}

/// Frees decoded images when the app goes to the background (they reload
/// from the disk cache on return), keeping the app's memory small so
/// Android keeps it alive longer and resuming is instant.
class _BackgroundMemoryTrim with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      PaintingBinding.instance.imageCache.clear();
    }
  }
}
