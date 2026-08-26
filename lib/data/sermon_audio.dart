class SermonAudio {
  final String id;
  final String title;
  final String description;
  final String audioUrl;
  final String mediaType; // "AUDIO" or "VIDEO"
  final String senderId;
  final String senderName;
  final int timestamp;

  SermonAudio({
    required this.id,
    required this.title,
    this.description = '',
    required this.audioUrl,
    required this.mediaType,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
  });

  /// Builds a SermonAudio from a Firebase Realtime Database snapshot map.
  /// Mirrors Firebase's automatic Kotlin data-class mapping — we do it
  /// manually here since Dart has no equivalent reflection-based mapping.
  factory SermonAudio.fromMap(String id, Map<dynamic, dynamic> map) {
    return SermonAudio(
      id: id,
      title: map['title'] as String? ?? '',
      description: map['description'] as String? ?? '',
      audioUrl: map['audioUrl'] as String? ?? '',
      mediaType: map['mediaType'] as String? ?? 'AUDIO',
      senderId: map['senderId'] as String? ?? '',
      senderName: map['senderName'] as String? ?? '',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'description': description,
      'audioUrl': audioUrl,
      'mediaType': mediaType,
      'senderId': senderId,
      'senderName': senderName,
      'timestamp': timestamp,
    };
  }

  SermonAudio copyWith({String? id}) {
    return SermonAudio(
      id: id ?? this.id,
      title: title,
      description: description,
      audioUrl: audioUrl,
      mediaType: mediaType,
      senderId: senderId,
      senderName: senderName,
      timestamp: timestamp,
    );
  }
}