/// Mirrors the Kotlin `ChatSummary` data class written to
/// `userChats/{uid}/{chatId}` in Firebase Realtime Database
/// (see writeChatSummaries() in PrivateChatScreen.kt).
class ChatSummary {
  final String chatId;
  final String otherUid;
  final String otherName;
  final String otherPhotoUrl; // Base64-encoded JPEG, not a URL
  final String lastMessage;
  final int lastTimestamp;
  final int unread;
  final int lastReadTimestamp;

  const ChatSummary({
    required this.chatId,
    required this.otherUid,
    required this.otherName,
    required this.otherPhotoUrl,
    required this.lastMessage,
    required this.lastTimestamp,
    required this.unread,
    required this.lastReadTimestamp,
  });

  factory ChatSummary.fromMap(String chatId, Map<dynamic, dynamic> map) {
    return ChatSummary(
      chatId: chatId,
      otherUid: (map['otherUid'] ?? '') as String,
      otherName: (map['otherName'] ?? '') as String,
      otherPhotoUrl: (map['otherPhotoUrl'] ?? '') as String,
      lastMessage: (map['lastMessage'] ?? '') as String,
      lastTimestamp: (map['lastTimestamp'] as num?)?.toInt() ?? 0,
      unread: (map['unread'] as num?)?.toInt() ?? 0,
      lastReadTimestamp: (map['lastReadTimestamp'] as num?)?.toInt() ?? 0,
    );
  }

  /// For writing back to `userChats/{uid}/{chatId}` in Firebase —
  /// mirrors the Kotlin `ChatSummary` data class's default serialization.
  Map<String, dynamic> toFirebaseMap() => {
    'otherUid': otherUid,
    'otherName': otherName,
    'otherPhotoUrl': otherPhotoUrl,
    'lastMessage': lastMessage,
    'lastTimestamp': lastTimestamp,
    'unread': unread,
    'lastReadTimestamp': lastReadTimestamp,
  };
}