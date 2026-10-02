import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// Android's native Kotlin stack (TelecomCallManager + CallService +
/// CallConnectionService + native WebRtcClient) owns calling there end to
/// end — ringing, signaling, and peer connections.
///
/// The Dart call stack (CallSignalingRepository's incoming-call listener,
/// CallInitiator, IncomingCallManager) must NEVER also run on Android.
/// Doing so is what caused the double-ring bug: both the native Telecom/
/// OneSignal path and this Dart RTDB listener were reacting to the same
/// "calls/{id}" write independently.
///
/// Place this check at the top of every Dart entry point into the calling
/// flow (starting the incoming-call listener, initiating a call, handling
/// an incoming call) so Android is a strict no-op for all of them.
bool get callsHandledNatively =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;