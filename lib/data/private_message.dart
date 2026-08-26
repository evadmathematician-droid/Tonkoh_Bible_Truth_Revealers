/// Mirrors the Kotlin `PrivateMessage` data class used for both the
/// Firebase relay node and the local (SQLite) store.
class PrivateMessage {
  final String id;
  final String text;
  final String type; // text | sticker | voice | image | video | audio | file
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
    );
  }

  static List<double> _parseWaveformCsv(String raw) {
    if (raw.isEmpty) return const [];
    return raw.split(',').map((s) => double.tryParse(s) ?? 0.0).toList();
  }

  static List<double> _parseWaveformList(Object? raw) {
    if (raw is List) {
      return raw.map((e) => (e as num).toDouble()).toList();
    }
    return const [];
  }
}