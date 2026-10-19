/// Content another app shared into TBTR ("Share → TBTR App"). Built from the
/// map MainActivity sends (ShareInbox.Payload.toMap in Kotlin).
///
/// TikTok and YouTube share a *link* (as text, often with words around it);
/// WhatsApp and the gallery share *files*, already copied into the app's
/// cache by ShareReceiverActivity.
class IncomingShare {
  final String text;
  final String subject;
  final List<SharedFile> files;

  /// "audio" when the user picked the "T.B.T.R – Audio Screen" Direct
  /// Share shortcut: the share screen opens with it selected.
  final String? target;

  const IncomingShare({
    this.text = '',
    this.subject = '',
    this.files = const [],
    this.target,
  });

  bool get toAudioScreen => target == 'audio';

  factory IncomingShare.fromMap(Map<dynamic, dynamic> map) {
    final rawFiles = map['files'];
    return IncomingShare(
      text: (map['text'] as String? ?? '').trim(),
      subject: (map['subject'] as String? ?? '').trim(),
      target: map['target'] as String?,
      files: rawFiles is List
          ? rawFiles
              .whereType<Map>()
              .map(SharedFile.fromMap)
              .where((f) => f.path.isNotEmpty)
              .toList()
          : const [],
    );
  }

  bool get isEmpty => text.isEmpty && files.isEmpty;

  /// First http(s) link in the shared text, if any.
  String? get link => firstLink(text);

  /// Text to post/send. Some apps put the title in the subject and only
  /// the bare link in the text (YouTube does) — keep both.
  String get message {
    if (subject.isEmpty || text.contains(subject)) return text;
    if (text.isEmpty) return subject;
    return '$subject\n$text';
  }
}

class SharedFile {
  final String path;
  final String mimeType;
  final String name;

  const SharedFile({
    required this.path,
    required this.mimeType,
    required this.name,
  });

  factory SharedFile.fromMap(Map<dynamic, dynamic> map) => SharedFile(
        path: map['path'] as String? ?? '',
        mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
        name: map['name'] as String? ?? 'shared',
      );

  /// "image" | "video" | "audio" | "file" — same buckets as chat attachments.
  String get kind {
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('video/')) return 'video';
    if (mimeType.startsWith('audio/')) return 'audio';
    return 'file';
  }

  /// Photos, videos and audio can go to the feed and to chats.
  bool get isMedia => kind != 'file';
}

final RegExp _linkPattern = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

/// First http(s) URL in [text], without trailing punctuation.
String? firstLink(String text) {
  final m = _linkPattern.firstMatch(text);
  if (m == null) return null;
  return m.group(0)!.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
}
