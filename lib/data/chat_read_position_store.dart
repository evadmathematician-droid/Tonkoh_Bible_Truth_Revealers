import 'package:shared_preferences/shared_preferences.dart';

/// Persists "how far I'd scrolled / which message I last saw" per
/// chat, so re-entering a chat jumps straight back there instead of
/// dumping the user at the very bottom every time.
///
/// Store the *message id* rather than a pixel offset — pixel offsets
/// break the moment bubble heights change (new message arrives,
/// waveform renders, font size changes, etc). An id is stable and you
/// can always re-locate it in the current message list.
class ChatReadPositionStore {
  ChatReadPositionStore._();
  static final ChatReadPositionStore instance = ChatReadPositionStore._();

  static const _prefix = 'last_read_message_id_';

  Future<void> saveLastRead(String chatId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$chatId', messageId);
  }

  Future<String?> getLastRead(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$chatId');
  }

  Future<void> clear(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$chatId');
  }
}