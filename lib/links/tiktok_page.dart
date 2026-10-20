import 'dart:convert';

/// What a TikTok video page tells us about the video.
class TikTokVideoInfo {
  final String caption;
  final String author; // display name
  final String authorId; // @handle
  final String coverUrl;
  final int width;
  final int height;
  final int durationSeconds;

  const TikTokVideoInfo({
    this.caption = '',
    this.author = '',
    this.authorId = '',
    this.coverUrl = '',
    this.width = 0,
    this.height = 0,
    this.durationSeconds = 0,
  });
}

/// The numeric video id of a TikTok video URL
/// (`/@user/video/<id>`, `/v/<id>.html`, `/embed/v2/<id>`), or null.
String? tiktokVideoId(String url) {
  final m = RegExp(r'/(?:video|v|embed/v2|embed)/(\d{8,25})').firstMatch(url);
  return m?.group(1);
}

/// Reads the video's caption, author, cover and duration from a TikTok
/// video page fetched with a desktop browser User-Agent (the page embeds
/// them in `__UNIVERSAL_DATA_FOR_REHYDRATION__`). TikTok's oEmbed no longer
/// returns a title or thumbnail, so this is the main source. Returns null
/// when the page doesn't carry the data (blocked, changed, or not a video).
TikTokVideoInfo? parseTikTokPage(String html) {
  final m = RegExp(
    r'<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>([\s\S]*?)</script>',
  ).firstMatch(html);
  if (m == null) return null;
  try {
    final root = jsonDecode(m.group(1)!);
    final item = (((root as Map)['__DEFAULT_SCOPE__']
        as Map?)?['webapp.video-detail'] as Map?)?['itemInfo']?['itemStruct'];
    if (item is! Map) return null;
    final video = item['video'] is Map ? item['video'] as Map : const {};
    final author = item['author'] is Map ? item['author'] as Map : const {};
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    final cover = [video['cover'], video['originCover'], video['dynamicCover']]
        .whereType<String>()
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    final info = TikTokVideoInfo(
      caption: (item['desc'] ?? '').toString().trim(),
      author: (author['nickname'] ?? '').toString().trim(),
      authorId: (author['uniqueId'] ?? '').toString().trim(),
      coverUrl: cover,
      width: n(video['width']),
      height: n(video['height']),
      durationSeconds: n(video['duration']),
    );
    if (info.caption.isEmpty && info.coverUrl.isEmpty && info.author.isEmpty) {
      return null;
    }
    return info;
  } catch (_) {
    return null;
  }
}
