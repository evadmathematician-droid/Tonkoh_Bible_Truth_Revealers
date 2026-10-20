import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Which player / app a link belongs to.
enum LinkKind { youtube, tiktok, other }

/// A WhatsApp-style preview of a shared link: thumbnail, title, text,
/// author and site. Created once by the sender (LinkPreviewService) and
/// stored inside the post / message under `link`, so receivers draw the
/// card instantly — offline too — without fetching anything.
///
/// Older app versions ignore the `link` map and show the message text
/// (which always still contains the URL).
@immutable
class LinkPreview {
  final String url;
  final String title;
  final String description;
  final String author;
  final String siteName;

  /// Durable image URL (YouTube's own thumbnail, or a Cloudinary copy of
  /// one that would expire). May be empty.
  final String thumbnailUrl;
  final int thumbWidth;
  final int thumbHeight;

  /// YouTube video id, when [url] is a YouTube video / Short.
  final String videoId;

  /// Text the sharing app sent along with the link (caption / description).
  final String sharedText;

  /// Video length when the site tells us (TikTok), for the card's badge.
  final int durationSeconds;

  /// Site favicon (other sites), shown next to the site name.
  final String iconUrl;

  /// Explicitly a video link (YouTube, TikTok, og:video…); see [isVideo].
  final bool video;

  const LinkPreview({
    required this.url,
    this.title = '',
    this.description = '',
    this.author = '',
    this.siteName = '',
    this.thumbnailUrl = '',
    this.thumbWidth = 0,
    this.thumbHeight = 0,
    this.videoId = '',
    this.sharedText = '',
    this.durationSeconds = 0,
    this.iconUrl = '',
    this.video = false,
  });

  /// A card with only what the link itself tells us (fetching failed).
  factory LinkPreview.basic(String url, {String sharedText = ''}) =>
      LinkPreview(
        url: url,
        siteName: siteNameFor(url),
        videoId: youtubeVideoId(url) ?? '',
        thumbnailUrl: _youtubeThumb(youtubeVideoId(url)),
        thumbWidth: youtubeVideoId(url) == null ? 0 : 480,
        thumbHeight: youtubeVideoId(url) == null ? 0 : 360,
        sharedText: sharedText,
      );

  LinkKind get kind {
    if (videoId.isNotEmpty || youtubeVideoId(url) != null) {
      return LinkKind.youtube;
    }
    if (isTikTokUrl(url)) return LinkKind.tiktok;
    return LinkKind.other;
  }

  /// Video links get a play button over the thumbnail.
  bool get isVideo =>
      video ||
      kind != LinkKind.other ||
      RegExp(r'(fb\.watch|/videos?/|/reel/|/watch)', caseSensitive: false)
          .hasMatch(url);

  bool get hasThumbnail => thumbnailUrl.isNotEmpty;

  /// Width / height of the thumbnail (16:9 when unknown), so the card
  /// reserves its exact height before the image loads.
  double get aspectRatio {
    if (thumbWidth > 0 && thumbHeight > 0) {
      return (thumbWidth / thumbHeight).clamp(0.5, 2.4).toDouble();
    }
    return 16 / 9;
  }

  LinkPreview copyWith({String? sharedText, String? thumbnailUrl}) =>
      LinkPreview(
        durationSeconds: durationSeconds,
        iconUrl: iconUrl,
        video: video,
        url: url,
        title: title,
        description: description,
        author: author,
        siteName: siteName,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        thumbWidth: thumbWidth,
        thumbHeight: thumbHeight,
        videoId: videoId,
        sharedText: sharedText ?? this.sharedText,
      );

  Map<String, Object?> toMap() => {
        'type': 'link',
        'url': url,
        'title': title,
        'description': description,
        'author': author,
        'siteName': siteName,
        'thumbnailUrl': thumbnailUrl,
        'thumbWidth': thumbWidth,
        'thumbHeight': thumbHeight,
        'videoId': videoId,
        'sharedText': sharedText,
        'isVideo': isVideo,
        if (durationSeconds > 0) 'durationSeconds': durationSeconds,
        if (iconUrl.isNotEmpty) 'iconUrl': iconUrl,
      };

  /// From a Firebase / JSON map; null when it isn't a usable preview.
  static LinkPreview? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final url = (raw['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    String s(String k) => (raw[k] ?? '').toString();
    return LinkPreview(
      url: url,
      title: s('title'),
      description: s('description'),
      author: s('author'),
      siteName: s('siteName'),
      thumbnailUrl: s('thumbnailUrl'),
      thumbWidth: n(raw['thumbWidth']),
      thumbHeight: n(raw['thumbHeight']),
      videoId: s('videoId'),
      sharedText: s('sharedText'),
      durationSeconds: n(raw['durationSeconds']),
      iconUrl: s('iconUrl'),
      video: raw['isVideo'] == true,
    );
  }

  String toJson() => jsonEncode(toMap());

  static LinkPreview? fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromMap(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LinkPreview && mapEquals(other.toMap(), toMap());

  @override
  int get hashCode => Object.hashAll(toMap().values);
}

// ── link detection ────────────────────────────────────────────────────

final RegExp _urlPattern = RegExp(
  r'((?:https?:\/\/|www\.)[^\s<>"]+)',
  caseSensitive: false,
);

/// First web link in [text] (http/https or www.), without trailing
/// punctuation, normalised to https:// for www. links.
String? extractFirstUrl(String text) {
  final m = _urlPattern.firstMatch(text);
  if (m == null) return null;
  var url = m.group(0)!.replaceFirst(RegExp(r'''[.,;:!?)\]}'"]+$'''), '');
  if (url.toLowerCase().startsWith('www.')) url = 'https://$url';
  return Uri.tryParse(url)?.hasAuthority == true ? url : null;
}

String _host(String url) => (Uri.tryParse(url)?.host ?? '')
    .toLowerCase()
    .replaceFirst(RegExp(r'^www\.'), '');

final RegExp _ytId = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// The 11-character video id of a YouTube watch / youtu.be / Shorts /
/// embed / live link, or null.
String? youtubeVideoId(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  final host =
      uri.host.toLowerCase().replaceFirst(RegExp(r'^(www\.|m\.|music\.)'), '');
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
  } else if (host == 'youtube.com' || host == 'youtube-nocookie.com') {
    final seg = uri.pathSegments;
    if (seg.isNotEmpty && seg.first == 'watch') {
      id = uri.queryParameters['v'];
    } else if (seg.length >= 2 &&
        const {'shorts', 'embed', 'live', 'v', 'e'}.contains(seg.first)) {
      id = seg[1];
    }
  }
  return (id != null && _ytId.hasMatch(id)) ? id : null;
}

bool isTikTokUrl(String url) {
  final h = _host(url);
  return h == 'tiktok.com' || h.endsWith('.tiktok.com');
}

/// vm.tiktok.com / vt.tiktok.com / tiktok.com/t/… — redirect to the real
/// video URL, which oEmbed needs.
bool isTikTokShortLink(String url) {
  final h = _host(url);
  if (h == 'vm.tiktok.com' || h == 'vt.tiktok.com') return true;
  final uri = Uri.tryParse(url);
  return h == 'tiktok.com' &&
      (uri?.pathSegments.isNotEmpty ?? false) &&
      uri!.pathSegments.first == 't';
}

/// Links that are only redirects to the real page.
bool isShortLink(String url) {
  final h = _host(url);
  return isTikTokShortLink(url) ||
      const {
        'fb.watch',
        'bit.ly',
        't.co',
        'tinyurl.com',
        'goo.gl',
        'instagr.am'
      }.contains(h);
}

/// "YouTube", "TikTok", "Facebook"… or the bare host for other sites.
String siteNameFor(String url) {
  final h = _host(url);
  if (youtubeVideoId(url) != null ||
      h.endsWith('youtube.com') ||
      h == 'youtu.be') {
    return 'YouTube';
  }
  if (h.endsWith('tiktok.com')) return 'TikTok';
  if (h.endsWith('facebook.com') || h == 'fb.watch' || h == 'fb.com') {
    return 'Facebook';
  }
  if (h.endsWith('instagram.com') || h == 'instagr.am') return 'Instagram';
  if (h == 'x.com' || h.endsWith('twitter.com')) return 'X';
  if (h.endsWith('whatsapp.com')) return 'WhatsApp';
  return h;
}

String _youtubeThumb(String? id) =>
    id == null ? '' : 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
