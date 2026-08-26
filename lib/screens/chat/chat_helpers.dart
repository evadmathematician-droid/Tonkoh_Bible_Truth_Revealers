import '../../data/private_message.dart';

// RTDB nodes shouldn't hold huge blobs — cap attachments so one message
// doesn't bloat sync size for every client in the chat. Applies to
// generic files; video/audio use maxVideoAudioBytes instead, since a
// single flat 2MB cap silently rejected almost every real video clip.
const int maxAttachmentBytes = 2000000; // ~2MB raw, ~2.7MB base64
const int maxVideoAudioBytes = 8000000; // ~8MB raw, ~10.9MB base64

/// Deterministic chat id for a pair of users, order-independent —
/// matches Kotlin's `privateChatId`.
String privateChatId(String uidA, String uidB) {
  final ids = [uidA, uidB]..sort();
  return ids.join('_');
}

/// Best-effort MIME type from a file extension when the picker doesn't
/// give one directly (mirrors the Kotlin fallback-to-extension logic).
String resolveMimeType(String? providedMime, String displayName) {
  if (providedMime != null && providedMime.isNotEmpty) return providedMime;

  final ext = displayName.contains('.') ? displayName.split('.').last.toLowerCase() : '';
  const map = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'wav': 'audio/wav',
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'txt': 'text/plain',
  };
  return map[ext] ?? 'application/octet-stream';
}

String attachmentTypeFromMime(String? mime) {
  if (mime == null) return 'file';
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  return 'file';
}

/// Preview text shown in chat-summary rows and reply quotes — matches
/// Kotlin's `previewLabelFor`.
String previewLabelFor(PrivateMessage message) {
  switch (message.type) {
    case 'sticker':
      return '🩹 Sticker';
    case 'voice':
      return '🎤 Voice message';
    case 'image':
      return '📷 Photo';
    case 'video':
      return '🎥 Video';
    case 'audio':
      return '🎵 ${message.fileName.isNotEmpty ? message.fileName : "Audio"}';
    case 'file':
      return '📎 ${message.fileName.isNotEmpty ? message.fileName : "File"}';
    default:
      return message.text;
  }
}