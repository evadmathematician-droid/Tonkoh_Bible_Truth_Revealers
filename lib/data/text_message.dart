import '../links/link_preview.dart';

class TextMessage {
  final String id;
  final String text;
  final int timestamp;
  final String replyToId;
  final String replyToType;
  final String replyToPreview;
  final String senderId;
  final String senderName;
  final String senderPhone;

  /// Preview card for a link in [text] (WhatsApp-style). [text] always
  /// still contains the URL, so older app versions show it as text.
  final LinkPreview? link;

  TextMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    this.replyToId = '',
    this.replyToType = '',
    this.replyToPreview = '',
    required this.senderId,
    required this.senderName,
    required this.senderPhone,
    this.link,
  });

  factory TextMessage.fromMap(String id, Map<dynamic, dynamic> map) {
    return TextMessage(
      id: id,
      text: map['text'] as String? ?? '',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      replyToId: map['replyToId'] as String? ?? '',
      replyToType: map['replyToType'] as String? ?? '',
      replyToPreview: map['replyToPreview'] as String? ?? '',
      senderId: map['senderId'] as String? ?? '',
      senderName: map['senderName'] as String? ?? '',
      senderPhone: map['senderPhone'] as String? ?? '',
      link: LinkPreview.fromMap(map['link']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'timestamp': timestamp,
      'replyToId': replyToId,
      'replyToType': replyToType,
      'replyToPreview': replyToPreview,
      'senderId': senderId,
      'senderName': senderName,
      'senderPhone': senderPhone,
      if (link != null) 'link': link!.toMap(),
    };
  }

  /// Row for the local SQLite feed cache (`LocalFeedStore`).
  Map<String, Object?> toDbMap() => {
        'id': id,
        'text': text,
        'timestamp': timestamp,
        'replyToId': replyToId,
        'replyToType': replyToType,
        'replyToPreview': replyToPreview,
        'senderId': senderId,
        'senderName': senderName,
        'senderPhone': senderPhone,
        'linkJson': link?.toJson() ?? '',
      };

  factory TextMessage.fromDbMap(Map<String, Object?> map) {
    return TextMessage(
      id: map['id'] as String,
      text: (map['text'] ?? '') as String,
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      replyToId: (map['replyToId'] ?? '') as String,
      replyToType: (map['replyToType'] ?? '') as String,
      replyToPreview: (map['replyToPreview'] ?? '') as String,
      senderId: (map['senderId'] ?? '') as String,
      senderName: (map['senderName'] ?? '') as String,
      senderPhone: (map['senderPhone'] ?? '') as String,
      link: LinkPreview.fromJson(map['linkJson'] as String?),
    );
  }
}
