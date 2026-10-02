import '../util/phone_utils.dart';

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

  ChatSummary copyWith({
    String? chatId,
    String? otherUid,
    String? otherName,
    String? otherPhotoUrl,
    String? lastMessage,
    int? lastTimestamp,
    int? unread,
    int? lastReadTimestamp,
  }) {
    return ChatSummary(
      chatId: chatId ?? this.chatId,
      otherUid: otherUid ?? this.otherUid,
      otherName: otherName ?? this.otherName,
      otherPhotoUrl: otherPhotoUrl ?? this.otherPhotoUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      lastTimestamp: lastTimestamp ?? this.lastTimestamp,
      unread: unread ?? this.unread,
      lastReadTimestamp: lastReadTimestamp ?? this.lastReadTimestamp,
    );
  }

  static final RegExp _phoneLike = RegExp(r'^\+?[0-9]{7,15}$');

  /// Groups a list of chat rows by the *person* they refer to, rather than
  /// by raw `chatId`, and keeps only the most recently active row per
  /// person (unread counts are summed across the merged rows).
  ///
  /// Why this is needed: a phone number identifies exactly one account. A
  /// number registered on several devices — a "mirror" — still shares that
  /// single account node, so it is still one person here. But legacy data,
  /// and numbers that older app versions (or a different device) stored in
  /// a slightly different format, can leave two or three
  /// `userChats/{uid}/{chatId}` entries that are really the same
  /// conversation, which showed up in the Discussions list as "2 or 3
  /// accounts of the same chat". Rows whose `otherUid` is a phone number
  /// are keyed by [loosePhoneKey] (last 9 significant digits) so those
  /// formatting differences collapse into one row. Rows with a
  /// non-phone id (very old anonymous-auth ids) are left untouched.
  static List<ChatSummary> dedupeByPerson(List<ChatSummary> input) {
    final chosen = <String, ChatSummary>{};
    final unreadTotals = <String, int>{};

    for (final c in input) {
      final key = _personKey(c);
      unreadTotals[key] = (unreadTotals[key] ?? 0) + c.unread;
      final existing = chosen[key];
      if (existing == null || c.lastTimestamp > existing.lastTimestamp) {
        chosen[key] = c;
      }
    }

    final out = chosen.entries
        .map((e) => e.value.copyWith(unread: unreadTotals[e.key]))
        .toList()
      ..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));
    return out;
  }

  static String _personKey(ChatSummary c) {
    final uid = c.otherUid.trim();
    if (_phoneLike.hasMatch(uid)) {
      final loose = loosePhoneKey(uid);
      if (loose != null) return 'phone:$loose';
    }
    return 'chat:${c.chatId}';
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