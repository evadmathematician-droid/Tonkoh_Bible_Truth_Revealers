import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../cloudinary/cloudinary_upload.dart';
import 'link_preview.dart';

/// Re-hosts a thumbnail image and returns its durable URL (null on failure).
typedef ThumbnailRehost = Future<String?> Function(Uint8List bytes);

/// Builds a [LinkPreview] for a link, like WhatsApp does when a link is
/// shared or typed:
///
///  * short links (vm.tiktok.com, fb.watch, …) are followed to the real URL;
///  * YouTube: oEmbed for title / channel, the video's own thumbnail;
///  * TikTok: oEmbed for caption / author / thumbnail;
///  * anything else: Open Graph tags (og:title, og:description, og:image,
///    og:site_name) from the page, fetched with a normal browser User-Agent.
///
/// TikTok's and most sites' thumbnail URLs expire, so those images are
/// downloaded once and re-uploaded to Cloudinary; the preview keeps the
/// Cloudinary URL. Videos themselves are never downloaded.
///
/// [fetch] never throws: whatever fails, the result is at least a card with
/// the link and the site name.
class LinkPreviewService {
  LinkPreviewService({http.Client? client, ThumbnailRehost? rehost})
      : _client = client ?? http.Client(),
        _rehost = rehost ?? _cloudinaryRehost;

  static final LinkPreviewService instance = LinkPreviewService();

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14; SM-A175F) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36';
  static const Duration _timeout = Duration(seconds: 10);
  static const int _maxHtmlBytes = 600 * 1024;
  static const int _maxImageBytes = 3 * 1024 * 1024;

  final http.Client _client;
  final ThumbnailRehost _rehost;
  final Map<String, Future<LinkPreview>> _cache = {};

  /// Preview for [url]; [sharedText] is the caption that came with it.
  Future<LinkPreview> fetch(String url, {String sharedText = ''}) async {
    final base = await (_cache[url] ??= _build(url));
    return sharedText.isEmpty ? base : base.copyWith(sharedText: sharedText);
  }

  Future<LinkPreview> _build(String original) async {
    try {
      final url = isShortLink(original) ? await resolveRedirects(original) : original;
      final videoId = youtubeVideoId(url);
      if (videoId != null) return await _youtube(url, videoId);
      if (isTikTokUrl(url)) return await _tiktok(url);
      return await _openGraph(url);
    } catch (e) {
      debugPrint('LinkPreviewService: $original failed: $e');
      _cache.remove(original); // try again next time
      return LinkPreview.basic(original);
    }
  }

  /// Follows HTTP redirects by hand (to learn the final URL), at most 6.
  Future<String> resolveRedirects(String url) async {
    var current = Uri.parse(url);
    for (var i = 0; i < 6; i++) {
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = _userAgent;
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
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(_timeout);
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<LinkPreview> _youtube(String url, String videoId) async {
    Map<String, dynamic>? o;
    try {
      o = await _getJson(Uri.parse(
          'https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(url)}'));
    } catch (_) {}
    // maxresdefault exists only for HD uploads; YouTube answers 404 otherwise.
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
    return parseYouTubeOEmbed(o, url: url, videoId: videoId).copyWithThumb(thumb, w, h);
  }

  Future<LinkPreview> _tiktok(String url) async {
    final o = await _getJson(Uri.parse(
        'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(url)}'));
    final p = parseTikTokOEmbed(o, url: url);
    return _withDurableThumb(p);
  }

  Future<LinkPreview> _openGraph(String url) async {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = _userAgent
      ..headers['Accept'] = 'text/html,application/xhtml+xml';
    final res = await _client.send(req).timeout(_timeout);
    if (res.statusCode != 200 ||
        !(res.headers['content-type'] ?? 'text/html').contains('html')) {
      await res.stream.drain<void>();
      return LinkPreview.basic(url);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(_timeout)) {
      bytes.add(chunk);
      if (bytes.length > _maxHtmlBytes) break; // the <head> is near the top
    }
    final html = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return _withDurableThumb(parseOpenGraph(html, url));
  }

  /// Copies an expiring thumbnail to Cloudinary; keeps the original URL if
  /// that fails (better a card that loses its image later than none).
  Future<LinkPreview> _withDurableThumb(LinkPreview p) async {
    if (!p.hasThumbnail) return p;
    try {
      final res = await _client
          .get(Uri.parse(p.thumbnailUrl), headers: {'User-Agent': _userAgent})
          .timeout(_timeout);
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

extension on LinkPreview {
  LinkPreview copyWithThumb(String thumb, int w, int h) => LinkPreview(
        url: url,
        title: title,
        description: description,
        author: author,
        siteName: siteName,
        thumbnailUrl: thumb,
        thumbWidth: w,
        thumbHeight: h,
        videoId: videoId,
        sharedText: sharedText,
      );
}

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
  );
}

/// TikTok oEmbed JSON → preview. TikTok's `title` is the caption.
LinkPreview parseTikTokOEmbed(Map<String, dynamic>? o, {required String url}) {
  if (o == null) return LinkPreview.basic(url);
  final caption = (o['title'] ?? '').toString().trim();
  final author = (o['author_name'] ?? '').toString().trim();
  return LinkPreview(
    url: url,
    title: caption.isNotEmpty ? caption : (author.isEmpty ? 'TikTok video' : '$author on TikTok'),
    author: author,
    siteName: 'TikTok',
    thumbnailUrl: (o['thumbnail_url'] ?? '').toString(),
    thumbWidth: _int(o['thumbnail_width']),
    thumbHeight: _int(o['thumbnail_height']),
  );
}

/// Open Graph / Twitter-card / <title> tags of an HTML page → preview.
LinkPreview parseOpenGraph(String html, String pageUrl) {
  final head = html.length > 200000 ? html.substring(0, 200000) : html;
  final metas = <String, String>{};
  for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(head)) {
    final tag = m.group(0)!;
    final key = _attr(tag, 'property') ?? _attr(tag, 'name') ?? _attr(tag, 'itemprop');
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
    title = t == null ? '' : _unescape(t.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim());
  }
  var image = pick(['og:image:secure_url', 'og:image', 'og:image:url', 'twitter:image', 'twitter:image:src']);
  if (image.isNotEmpty) {
    image = Uri.parse(pageUrl).resolve(image).toString();
  }
  return LinkPreview(
    url: pageUrl,
    title: title,
    description: pick(['og:description', 'twitter:description', 'description']),
    author: pick(['author', 'article:author', 'og:video:director']),
    siteName: pick(['og:site_name']).isNotEmpty ? pick(['og:site_name']) : siteNameFor(pageUrl),
    thumbnailUrl: image,
    thumbWidth: _int(pick(['og:image:width'])),
    thumbHeight: _int(pick(['og:image:height'])),
    videoId: youtubeVideoId(pageUrl) ?? '',
  );
}

String? _attr(String tag, String name) {
  final m = RegExp('\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')', caseSensitive: false)
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
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)));
