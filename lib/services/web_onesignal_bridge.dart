// web_onesignal_bridge.dart
// Only imported/used when running on web (kIsWeb).
import 'dart:async';
import 'dart:js_interop';

@JS('tonkohRequestPushPermission')
external JSPromise<JSAny?> _requestPushPermission();

@JS('tonkohGetSubscriptionId')
external JSPromise<JSString?> _getSubscriptionId();

@JS('tonkohOnSubscriptionChange')
external void _onSubscriptionChange(JSFunction callback);

class WebOneSignalBridge {
  /// Triggers the browser's native permission prompt.
  static Future<void> requestPermission() async {
    await _requestPushPermission().toDart;
  }

  /// One-shot fetch of the current subscription id (may be null
  /// if the user hasn't granted permission yet).
  static Future<String?> getSubscriptionId() async {
    final result = await _getSubscriptionId().toDart;
    return result?.toDart;
  }

  /// Registers a callback that fires whenever the subscription id
  /// becomes available or changes (mirrors your Android observer).
  static void onSubscriptionChange(void Function(String id) onChange) {
    _onSubscriptionChange(
          (JSString id) {
        onChange(id.toDart);
      }.toJS,
    );
  }
}