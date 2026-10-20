import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../cloudinary/cloudinary_upload.dart';
import 'link_preview.dart';
import 'link_preview_cache.dart';
import 'tiktok_page.dart';

/// Re-hosts a thumbnail image and returns its durable URL (null on failure).
typedef ThumbnailRehost = Future<String?> Function(Uint8List bytes);

/// Builds a [LinkPreview] for a link, like WhatsApp does when a link is
/// shared or typed:
///
///  * short links (vm.tiktok.com, fb.watch, …) are followed to the real URL;
///  * YouTube: oEmbed for title / channel, the video's own thumbnail
///    (maxresdefault when it exists, else hqdefault);
///  * TikTok: the video page's embedded data (caption, author, vertical
///    cover, duration) — TikTok's oEmbed no longer returns a title or
///    thumbnail — then oEmbed, then the page's Open Graph tags;
///  * anything else: Open Graph / Twitter-card tags, `<title>`, favicon and
///    og:video from the page (8 s, at most 1 MB).
///
/// Thumbnails that expire (TikTok, Facebook, Instagram, most sites) are
/// downloaded once and re-uploaded to Cloudinary when the preview is going
/// into a message ([fetch] `rehost: true`). Videos are never downloaded.
/// Results are cached on the phone by URL ([LinkPreviewCache]).
///
/// [fetch] never throws: whatever fails, the result is at least a card with
/// the link and the site name.
class LinkPreviewService {
  LinkPreviewService({
    http.Client? client,
    ThumbnailRehost? rehost,
    LinkPreviewCache? cache,
  })  : _client = client ?? http.Client(),
        _rehost = rehost ?? _cloudinaryRehost,
        _cache = cache;

  static final LinkPreviewService instance =
      LinkPreviewService(cache: LinkPreviewCache.instance);

  static const String _mobileUA =
      'Mozilla/5.0 (Linux; Android 14; SM-A175F) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36';
  static const String _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
  // What WhatsApp / Facebook use to read previews; sites that hide their
  // tags from browsers (TikTok, Instagram, Facebook) serve them to it.
  static const String _crawlerUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  static const Duration _timeout = Duration(seconds: 8);
  static const int _maxHtmlBytes = 1024 * 1024;
  static const int _maxImageBytes = 3 * 1024 * 1024;

  final http.Client _client;
  final ThumbnailRehost _rehost;
  final LinkPreviewCache? _cache;
  final Map<String, Future<LinkPreview>> _inFlight = {};

  /// The preview cached on this phone for [url], if any (instant).
  LinkPreview? cached(String url) => _cache?.peek(url);

  /// Preview for [url]. [sharedText] is the caption that came with it.
  /// [rehost]: copy an expiring thumbnail to Cloudinary (only when the
  /// preview is saved into a message/post, not when just displaying).
  Future<LinkPreview> fetch(String url,
      {String sharedText = '', bool rehost = true}) async {
    var base = await _cache?.get(url);
    if (base == null || (rehost && _needsRehost(base))) {
      final key = '$url|$rehost';
      base = await (_inFlight[key] ??=
          // (Block body: returning the removed Future would make it wait
          // on itself.)
          _build(url, rehost: rehost).whenComplete(() {
        _inFlight.remove(key);
      }));
    }
    return sharedText.isEmpty ? base : base.copyWith(sharedText: sharedText);
  }

  bool _needsRehost(LinkPreview p) =>
      p.hasThumbnail &&
      p.kind != LinkKind.youtube &&
      !p.thumbnailUrl.contains('res.cloudinary.com');

  Future<LinkPreview> _build(String original, {required bool rehost}) async {
    try {
      final url =
          isShortLink(original) ? await resolveRedirects(original) : original;
      final videoId = youtubeVideoId(url);
      LinkPreview p;
      if (videoId != null) {
        p = await _youtube(url, videoId);
      } else if (isTikTokUrl(url)) {
        p = await _tiktok(url);
      } else {
        p = await _openGraph(url);
      }
      if (rehost) p = await _withDurableThumb(p);
      // Keyed by what the user pasted, so the same link is instant next time.
      final keyed = p.url == original ? p : _withUrl(p, original);
      if (keyed.title.isNotEmpty || keyed.hasThumbnail) {
        await _cache?.put(original, keyed);
      }
      return keyed;
    } catch (e) {
      debugPrint('LinkPreviewService: $original failed: $e');
      return LinkPreview.basic(original);
    }
  }

  /// Follows HTTP redirects by hand (to learn the final URL), at most 6.
  Future<String> resolveRedirects(String url) async {
    var current = Uri.parse(url);
    for (var i = 0; i < 6; i++) {
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = _desktopUA;
      final res = await _client.send(req).timeout(_timeout);
      final location = res.headers['location'];
      await res.stream.drain<void>();
      if (res.statusCode < 300 || res.statusCode >= 400 || location == null) {
        break;
      }
      current = current.resolve(location);
    }
    return current.toString();
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    final res = await _client
        .get(uri, headers: {'User-Agent': _desktopUA}).timeout(_timeout);
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<String?> _getHtml(String url, String userAgent) async {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = userAgent
      ..headers['Accept'] = 'text/html,application/xhtml+xml'
      ..headers['Accept-Language'] = 'en';
    final res = await _client.send(req).timeout(_timeout);
    if (res.statusCode != 200 ||
        !(res.headers['content-type'] ?? 'text/html').contains('html')) {
      await res.stream.drain<void>();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(_timeout)) {
      bytes.add(chunk);
      if (bytes.length > _maxHtmlBytes) break;
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<LinkPreview> _youtube(String url, String videoId) async {
    Map<String, dynamic>? o;
    try {
      o = await _getJson(Uri.parse(
          'https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(url)}'));
    } catch (_) {}
    var thumb = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    var w = 480, h = 360;
    try {
      final maxres = 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg';
      final head = await _client.head(Uri.parse(maxres)).timeout(_timeout);
      if (head.statusCode == 200) {
        thumb = maxres;
        w = 1280;
        h = 720;
      }
    } catch (_) {}
    return _copy(parseYouTubeOEmbed(o, url: url, videoId: videoId),
        thumbnailUrl: thumb, thumbWidth: w, thumbHeight: h);
  }

  Future<LinkPreview> _tiktok(String url) async {
    // 1. The video page (desktop browser) carries caption, author, cover.
    try {
      final html = await _getHtml(url, _desktopUA);
      final info = html == null ? null : parseTikTokPage(html);
      if (info != null) return tiktokPreviewFromPage(info, url);
    } catch (_) {}
    // 2. oEmbed (sometimes still has the fields).
    LinkPreview? fromOEmbed;
    try {
      final o = await _getJson(Uri.parse(
          'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(url)}'));
      fromOEmbed = parseTikTokOEmbed(o, url: url);
      if (fromOEmbed.hasThumbnail && fromOEmbed.title != 'TikTok video') {
        return fromOEmbed;
      }
    } catch (_) {}
    // 3. Open Graph tags served to link-preview crawlers.
    try {
      final html = await _getHtml(url, _crawlerUA);
      if (html != null) {
        final og = parseOpenGraph(html, url);
        if (og.hasThumbnail || og.title.isNotEmpty) {
          return _copy(og, siteName: 'TikTok', video: true);
        }
      }
    } catch (_) {}
    return fromOEmbed ?? _copy(LinkPreview.basic(url), video: true);
  }

  Future<LinkPreview> _openGraph(String url) async {
    final site = siteNameFor(url);
    final crawlerFirst = site == 'Facebook' || site == 'Instagram';
    for (final ua
        in crawlerFirst ? [_crawlerUA, _mobileUA] : [_mobileUA, _crawlerUA]) {
      try {
        final html = await _getHtml(url, ua);
        if (html == null) continue;
        final p = parseOpenGraph(html, url);
        if (p.title.isNotEmpty || p.hasThumbnail) return p;
      } catch (_) {}
    }
    return LinkPreview.basic(url);
  }

  /// Copies an expiring thumbnail to Cloudinary; keeps the original URL if
  /// that fails (better a card that loses its image later than none).
  Future<LinkPreview> _withDurableThumb(LinkPreview p) async {
    if (!_needsRehost(p)) return p;
    try {
      final res = await _client.get(Uri.parse(p.thumbnailUrl),
          headers: {'User-Agent': _desktopUA}).timeout(_timeout);
      if (res.statusCode == 200 &&
          res.bodyBytes.isNotEmpty &&
          res.bodyBytes.length <= _maxImageBytes) {
        final durable = await _rehost(res.bodyBytes);
        if (durable != null) return p.copyWith(thumbnailUrl: durable);
      }
    } catch (e) {
      debugPrint('LinkPreviewService: thumbnail copy failed: $e');
    }
    return p;
  }

  static Future<String?> _cloudinaryRehost(Uint8List bytes) async {
    String? url;
    await uploadToCloudinary(
      fileBytes: bytes,
      fileName: 'link_thumb_${DateTime.now().millisecondsSinceEpoch}.jpg',
      resourceType: 'image',
      folder: 'link_previews',
      onSuccess: (u) => url = u,
      onError: (_) {},
    );
    return url;
  }
}

LinkPreview _copy(
  LinkPreview p, {
  String? thumbnailUrl,
  int? thumbWidth,
  int? thumbHeight,
  String? siteName,
  bool? video,
}) =>
    LinkPreview(
      url: p.url,
      title: p.title,
      description: p.description,
      author: p.author,
      siteName: siteName ?? p.siteName,
      thumbnailUrl: thumbnailUrl ?? p.thumbnailUrl,
      thumbWidth: thumbWidth ?? p.thumbWidth,
      thumbHeight: thumbHeight ?? p.thumbHeight,
      videoId: p.videoId,
      sharedText: p.sharedText,
      durationSeconds: p.durationSeconds,
      iconUrl: p.iconUrl,
      video: video ?? p.video,
    );

LinkPreview _withUrl(LinkPreview p, String url) => LinkPreview(
      url: url,
      title: p.title,
      description: p.description,
      author: p.author,
      siteName: p.siteName,
      thumbnailUrl: p.thumbnailUrl,
      thumbWidth: p.thumbWidth,
      thumbHeight: p.thumbHeight,
      videoId: p.videoId,
      sharedText: p.sharedText,
      durationSeconds: p.durationSeconds,
      iconUrl: p.iconUrl,
      video: p.video,
    );

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// YouTube oEmbed JSON → preview ([o] may be null if the call failed).
LinkPreview parseYouTubeOEmbed(Map<String, dynamic>? o,
    {required String url, required String videoId}) {
  return LinkPreview(
    url: url,
    title: (o?['title'] ?? '').toString().trim(),
    author: (o?['author_name'] ?? '').toString().trim(),
    siteName: 'YouTube',
    videoId: videoId,
    thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    thumbWidth: 480,
    thumbHeight: 360,
    video: true,
  );
}

/// TikTok page data → preview: the caption is the text, the author's name
/// and handle the byline.
LinkPreview tiktokPreviewFromPage(TikTokVideoInfo info, String url) {
  final byline = [
    if (info.author.isNotEmpty) info.author,
    if (info.authorId.isNotEmpty) '@${info.authorId}',
  ].join(' · ');
  final title = info.caption.isNotEmpty
      ? info.caption
      : (info.author.isNotEmpty ? '${info.author} on TikTok' : 'TikTok video');
  return LinkPreview(
    url: url,
    title: title,
    author: byline,
    siteName: 'TikTok',
    thumbnailUrl: info.coverUrl,
    thumbWidth: info.width,
    thumbHeight: info.height,
    durationSeconds: info.durationSeconds,
    video: true,
  );
}

/// TikTok oEmbed JSON → preview. TikTok's `title` is the caption (when it
/// sends one at all).
LinkPreview parseTikTokOEmbed(Map<String, dynamic>? o, {required String url}) {
  if (o == null) return LinkPreview.basic(url);
  final caption = (o['title'] ?? '').toString().trim();
  final author = (o['author_name'] ?? '').toString().trim();
  return LinkPreview(
    url: url,
    title: caption.isNotEmpty
        ? caption
        : (author.isEmpty ? 'TikTok video' : '$author on TikTok'),
    author: author,
    siteName: 'TikTok',
    thumbnailUrl: (o['thumbnail_url'] ?? '').toString(),
    thumbWidth: _int(o['thumbnail_width']),
    thumbHeight: _int(o['thumbnail_height']),
    video: true,
  );
}

/// Open Graph / Twitter-card / `<title>` / favicon tags of an HTML page →
/// preview.
LinkPreview parseOpenGraph(String html, String pageUrl) {
  final head = html.length > 300000 ? html.substring(0, 300000) : html;
  final metas = <String, String>{};
  for (final m
      in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(head)) {
    final tag = m.group(0)!;
    final key =
        _attr(tag, 'property') ?? _attr(tag, 'name') ?? _attr(tag, 'itemprop');
    final content = _attr(tag, 'content');
    if (key == null || content == null) continue;
    metas.putIfAbsent(key.toLowerCase(), () => _unescape(content.trim()));
  }
  String pick(List<String> keys) {
    for (final k in keys) {
      final v = metas[k];
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  var title = pick(['og:title', 'twitter:title']);
  if (title.isEmpty) {
    final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false)
        .firstMatch(head);
    title = t == null
        ? ''
        : _unescape(t.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim());
  }
  final base = Uri.parse(pageUrl);
  String resolve(String u) => u.isEmpty ? '' : base.resolve(u).toString();
  final image = resolve(pick([
    'og:image:secure_url',
    'og:image',
    'og:image:url',
    'twitter:image',
    'twitter:image:src'
  ]));

  var icon = '';
  for (final m
      in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(head)) {
    final tag = m.group(0)!;
    final rel = (_attr(tag, 'rel') ?? '').toLowerCase();
    if (!rel.contains('icon')) continue;
    final href = _attr(tag, 'href');
    if (href == null || href.isEmpty) continue;
    icon = resolve(_unescape(href));
    if (rel.contains('apple-touch-icon')) break; // the sharpest one
  }

  final ogType = pick(['og:type']);
  return LinkPreview(
    url: pageUrl,
    title: title,
    description: pick(['og:description', 'twitter:description', 'description']),
    author: pick(['author', 'article:author', 'og:video:director']),
    siteName: pick(['og:site_name']).isNotEmpty
        ? pick(['og:site_name'])
        : siteNameFor(pageUrl),
    thumbnailUrl: image,
    thumbWidth: _int(pick(['og:image:width'])),
    thumbHeight: _int(pick(['og:image:height'])),
    videoId: youtubeVideoId(pageUrl) ?? '',
    iconUrl: icon,
    video:
        pick(['og:video', 'og:video:url', 'og:video:secure_url']).isNotEmpty ||
            ogType.startsWith('video'),
  );
}

String? _attr(String tag, String name) {
  final m =
      RegExp('\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')', caseSensitive: false)
          .firstMatch(tag);
  return m == null ? null : (m.group(2) ?? m.group(3));
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAllMapped(RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)));
