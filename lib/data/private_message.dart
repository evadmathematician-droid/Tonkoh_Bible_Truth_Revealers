import '../links/link_preview.dart';

/// Delivery state of a message *I* sent, kept only on this phone.
class MessageStatus {
  MessageStatus._();

  /// Saved locally, not yet acknowledged by Firebase (offline / sending).
  static const int pending = 0;

  /// On the server — the recipient's phone hasn't picked it up yet.
  static const int sent = 1;

  /// The recipient's phone saved it (it removed the relay copy).
  static const int delivered = 2;
}

/// Mirrors the Kotlin `PrivateMessage` data class used for both the
/// Firebase relay node and the local (SQLite) store.
class PrivateMessage {
  final String id;
  final String text;
  final String type; // text | link | sticker | voice | image | video | audio | file
  final int timestamp;
  final String senderId;
  final String senderName;
  final String senderPhone;

  final String replyToId;
  final String replyToText;
  final String replyToSenderName;

  final String stickerId;

  final String audioUrl; // base64, voice notes
  final int duration; // seconds, voice notes

  final String fileUrl; // base64, image/video/audio/file attachments
  final String fileName;
  final String mimeType;

  /// Normalized (0.0-1.0) amplitude bars for a voice note's waveform
  /// display, e.g. from `VoiceRecording.waveform`. Empty for every
  /// type other than 'voice'.
  final List<double> waveform;

  /// true = the recipient has played / read this message.
  final bool listened;

  /// [MessageStatus] — local only, never sent to Firebase. Messages from
  /// the other person are always [MessageStatus.sent].
  final int status;

  /// Preview card for type "link" (WhatsApp-style). [text] still holds the
  /// URL, so older app versions show the message as plain text.
  final LinkPreview? link;

  const PrivateMessage({
    required this.id,
    this.text = '',
    this.type = 'text',
    required this.timestamp,
    required this.senderId,
    this.senderName = '',
    this.senderPhone = '',
    this.replyToId = '',
    this.replyToText = '',
    this.replyToSenderName = '',
    this.stickerId = '',
    this.audioUrl = '',
    this.duration = 0,
    this.fileUrl = '',
    this.fileName = '',
    this.mimeType = '',
    this.waveform = const [],
    this.listened = false,
    this.status = MessageStatus.sent,
    this.link,
  });

  PrivateMessage copyWith({
    String? id,
    String? text,
    String? type,
    int? timestamp,
    String? senderId,
    String? senderName,
    String? senderPhone,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? stickerId,
    String? audioUrl,
    int? duration,
    String? fileUrl,
    String? fileName,
    String? mimeType,
    List<double>? waveform,
    bool? listened,
    int? status,
    LinkPreview? link,
  }) {
    return PrivateMessage(
      id: id ?? this.id,
      text: text ?? this.text,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      senderPhone: senderPhone ?? this.senderPhone,
      replyToId: replyToId ?? this.replyToId,
      replyToText: replyToText ?? this.replyToText,
      replyToSenderName: replyToSenderName ?? this.replyToSenderName,
      stickerId: stickerId ?? this.stickerId,
      audioUrl: audioUrl ?? this.audioUrl,
      duration: duration ?? this.duration,
      fileUrl: fileUrl ?? this.fileUrl,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      waveform: waveform ?? this.waveform,
      listened: listened ?? this.listened,
      status: status ?? this.status,
      link: link ?? this.link,
    );
  }

  /// For pushing to Firebase (`privateChats/{chatId}/messages/{id}`).
  Map<String, dynamic> toFirebaseMap() => {
    'id': id,
    'text': text,
    'type': type,
    'timestamp': timestamp,
    'senderId': senderId,
    'senderName': senderName,
    'senderPhone': senderPhone,
    'replyToId': replyToId,
    'replyToText': replyToText,
    'replyToSenderName': replyToSenderName,
    'stickerId': stickerId,
    'audioUrl': audioUrl,
    'duration': duration,
    'fileUrl': fileUrl,
    'fileName': fileName,
    'mimeType': mimeType,
    'waveform': waveform,
    'listened': listened,
    if (link != null) 'link': link!.toMap(),
  };

  factory PrivateMessage.fromFirebaseMap(String id, Map<dynamic, dynamic> map) {
    return PrivateMessage(
      id: id,
      text: (map['text'] ?? '') as String,
      type: (map['type'] ?? 'text') as String,
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      senderId: (map['senderId'] ?? '') as String,
      senderName: (map['senderName'] ?? '') as String,
      senderPhone: (map['senderPhone'] ?? '') as String,
      replyToId: (map['replyToId'] ?? '') as String,
      replyToText: (map['replyToText'] ?? '') as String,
      replyToSenderName: (map['replyToSenderName'] ?? '') as String,
      stickerId: (map['stickerId'] ?? '') as String,
      audioUrl: (map['audioUrl'] ?? '') as String,
      duration: (map['duration'] as num?)?.toInt() ?? 0,
      fileUrl: (map['fileUrl'] ?? '') as String,
      fileName: (map['fileName'] ?? '') as String,
      mimeType: (map['mimeType'] ?? '') as String,
      waveform: _parseWaveformList(map['waveform']),
      listened: (map['listened'] as bool?) ?? false,
      link: LinkPreview.fromMap(map['link']),
    );
  }

  /// For the local SQLite store (LocalChatStore). chatId is stored as a
  /// column here since one table holds every conversation.
  Map<String, Object?> toDbMap(String chatId) => {
    'id': id,
    'chatId': chatId,
    'text': text,
    'type': type,
    'timestamp': timestamp,
    'senderId': senderId,
    'senderName': senderName,
    'senderPhone': senderPhone,
    'replyToId': replyToId,
    'replyToText': replyToText,
    'replyToSenderName': replyToSenderName,
    'stickerId': stickerId,
    'audioUrl': audioUrl,
    'duration': duration,
    'fileUrl': fileUrl,
    'fileName': fileName,
    'mimeType': mimeType,
    // SQLite has no native list type, so store as a comma-joined
    // string — decoded back into List<double> in fromDbMap.
    'waveform': waveform.join(','),
    'listened': listened ? 1 : 0,
    'status': status,
    'linkJson': link?.toJson() ?? '',
  };

  factory PrivateMessage.fromDbMap(Map<String, Object?> map) {
    return PrivateMessage(
      id: map['id'] as String,
      text: (map['text'] ?? '') as String,
      type: (map['type'] ?? 'text') as String,
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      senderId: (map['senderId'] ?? '') as String,
      senderName: (map['senderName'] ?? '') as String,
      senderPhone: (map['senderPhone'] ?? '') as String,
      replyToId: (map['replyToId'] ?? '') as String,
      replyToText: (map['replyToText'] ?? '') as String,
      replyToSenderName: (map['replyToSenderName'] ?? '') as String,
      stickerId: (map['stickerId'] ?? '') as String,
      audioUrl: (map['audioUrl'] ?? '') as String,
      duration: (map['duration'] as num?)?.toInt() ?? 0,
      fileUrl: (map['fileUrl'] ?? '') as String,
      fileName: (map['fileName'] ?? '') as String,
      mimeType: (map['mimeType'] ?? '') as String,
      waveform: _parseWaveformCsv((map['waveform'] ?? '') as String),
      listened: (map['listened'] as int? ?? 0) == 1,
      status: (map['status'] as int?) ?? MessageStatus.sent,
      link: LinkPreview.fromJson(map['linkJson'] as String?),
    );
  }

  static List<double> _parseWaveformCsv(String raw) {
    if (raw.isEmpty) return const [];
    return raw.split(',').map((s) => double.tryParse(s) ?? 0.0).toList();
  }

  static List<double> _parseWaveformList(Object? raw) {
    // Firebase RTDB returns a stored list as a List when the indices are
    // dense (0..n), but as a Map<String,dynamic> keyed by index string when
    // they're sparse — and either form can contain nulls. Handle all of it
    // so the recipient's waveform never silently comes back empty.
    Iterable<Object?> values;
    if (raw is List) {
      values = raw;
    } else if (raw is Map) {
      final entries = raw.entries
          .map((e) => MapEntry(int.tryParse(e.key.toString()) ?? -1, e.value))
          .where((e) => e.key >= 0)
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      values = entries.map((e) => e.value);
    } else {
      return const [];
    }
    return values
        .map((e) => e is num ? e.toDouble() : 0.0)
        .toList();
  }
}