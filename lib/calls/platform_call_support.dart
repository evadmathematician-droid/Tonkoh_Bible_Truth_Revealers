/// Whether the native Kotlin call stack (TelecomCallManager + CallService +
/// CallConnectionService + native WebRtcClient) owns calling on this
/// platform, meaning the Dart stack (CallSignalingRepository listener,
/// CallInitiator, IncomingCallManager) must stay a no-op.
///
/// Now **always false**: Android is on the same Flutter / flutter_webrtc
/// call path as web and iOS. The native Telecom stack
/// (`TelecomCallManager` / `CallService` / `CallConnectionService`) stays
/// retired.
///
/// Killed / backgrounded incoming calls are still restored on Android, but
/// via a lightweight path rather than Telecom: the OneSignal call push runs
/// `CallNotificationServiceExtension`, which posts a `CATEGORY_CALL`
/// full-screen notification that launches `MainActivity` with call extras;
/// `NativeCallBridge` (Dart) turns those into the normal
/// [IncomingCallManager] flow. The extension bails when the app is
/// foreground, so the in-app RTDB listener remains the sole handler there
/// and there is no double ring.
bool get callsHandledNatively => false;