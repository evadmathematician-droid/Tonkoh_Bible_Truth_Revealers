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
    };
  }
}