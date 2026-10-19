import '../links/link_preview.dart';

class SermonAudio {
  final String id;
  final String title;

  /// The full description the uploader typed (upload_sheet.dart writes it to
  /// `description`; `title` is just its first 40 chars). Shown in the feed
  /// under audio items. May be empty for older records.
  final String description;
  final String audioUrl;

  /// "AUDIO", "IMAGE", "VIDEO" (see upload_sheet.dart) or "LINK" — a
  /// YouTube / TikTok / web link shared into the Audio screen, drawn from
  /// [link]. LINK posts leave [audioUrl] empty, so older app versions
  /// (which skip posts without one) simply don't show them.
  final String mediaType;
  final String senderId;
  final String senderName;
  final int timestamp;

  /// Rich preview for LINK posts.
  final LinkPreview? link;

  SermonAudio({
    required this.id,
    required this.title,
    this.description = '',
    required this.audioUrl,
    required this.mediaType,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    this.link,
  });

  bool get isLink => mediaType.toUpperCase() == 'LINK' && link != null;

  /// Something the feed can draw: a media URL, or a link preview.
  bool get isDisplayable => audioUrl.isNotEmpty || isLink;

  /// Builds a SermonAudio from a Firebase Realtime Database snapshot map.
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
      link: LinkPreview.fromMap(map['link']),
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
      if (link != null) 'link': link!.toMap(),
    };
  }

  /// Row for the local SQLite feed cache (`LocalFeedStore`). Mirrors the
  /// Firebase shape but carries `id` as a column.
  Map<String, Object?> toDbMap() => {
        'id': id,
        'title': title,
        'description': description,
        'audioUrl': audioUrl,
        'mediaType': mediaType,
        'senderId': senderId,
        'senderName': senderName,
        'timestamp': timestamp,
        'linkJson': link?.toJson() ?? '',
      };

  factory SermonAudio.fromDbMap(Map<String, Object?> map) {
    return SermonAudio(
      id: map['id'] as String,
      title: (map['title'] ?? '') as String,
      description: (map['description'] ?? '') as String,
      audioUrl: (map['audioUrl'] ?? '') as String,
      mediaType: (map['mediaType'] ?? 'AUDIO') as String,
      senderId: (map['senderId'] ?? '') as String,
      senderName: (map['senderName'] ?? '') as String,
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      link: LinkPreview.fromJson(map['linkJson'] as String?),
    );
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
      link: link,
    );
  }
}
