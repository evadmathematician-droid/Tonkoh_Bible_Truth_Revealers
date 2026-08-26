// Stub so non-web platforms compile without dart:js_interop.
class WebOneSignalBridge {
  static Future<void> requestPermission() async {}
  static Future<String?> getSubscriptionId() async => null;
  static void onSubscriptionChange(void Function(String id) onChange) {}
}