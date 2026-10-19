import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tbtrapp/data/private_message.dart';
import 'package:tbtrapp/links/link_preview.dart';
import 'package:tbtrapp/links/link_preview_service.dart';

void main() {
  group('link detection', () {
    test('first URL in shared text, trailing punctuation dropped', () {
      expect(
          extractFirstUrl('Watch this! https://youtu.be/dQw4w9WgXcQ?si=abc.'),
          'https://youtu.be/dQw4w9WgXcQ?si=abc');
      expect(extractFirstUrl('see www.example.org/page)'),
          'https://www.example.org/page');
      expect(extractFirstUrl('no link here'), isNull);
    });

    test('YouTube ids: watch, youtu.be, Shorts, embed, live, mobile', () {
      const id = 'dQw4w9WgXcQ';
      for (final u in [
        'https://www.youtube.com/watch?v=$id&t=42s',
        'https://m.youtube.com/watch?v=$id',
        'https://youtu.be/$id?si=XYZ',
        'https://www.youtube.com/shorts/$id',
        'https://youtube.com/shorts/$id?feature=share',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube.com/live/$id',
        'https://music.youtube.com/watch?v=$id',
      ]) {
        expect(youtubeVideoId(u), id, reason: u);
      }
      expect(youtubeVideoId('https://www.youtube.com/channel/UC123'), isNull);
      expect(youtubeVideoId('https://example.com/watch?v=$id'), isNull);
    });

    test('TikTok links and short links', () {
      expect(isTikTokUrl('https://www.tiktok.com/@a/video/123'), isTrue);
      expect(isTikTokShortLink('https://vm.tiktok.com/ZMabc/'), isTrue);
      expect(isTikTokShortLink('https://vt.tiktok.com/ZSabc/'), isTrue);
      expect(isTikTokShortLink('https://www.tiktok.com/t/ZTabc/'), isTrue);
      expect(isTikTokShortLink('https://www.tiktok.com/@a/video/1'), isFalse);
    });

    test('site names', () {
      expect(siteNameFor('https://youtu.be/dQw4w9WgXcQ'), 'YouTube');
      expect(siteNameFor('https://vm.tiktok.com/x'), 'TikTok');
      expect(siteNameFor('https://fb.watch/abc'), 'Facebook');
      expect(siteNameFor('https://www.instagram.com/reel/x'), 'Instagram');
      expect(siteNameFor('https://www.bbc.com/news'), 'bbc.com');
    });
  });

  group('metadata parsing', () {
    test('YouTube oEmbed', () {
      final p = parseYouTubeOEmbed(
          {'title': 'Sunday Sermon', 'author_name': 'TBTR Channel'},
          url: 'https://youtu.be/dQw4w9WgXcQ', videoId: 'dQw4w9WgXcQ');
      expect(p.title, 'Sunday Sermon');
      expect(p.author, 'TBTR Channel');
      expect(p.siteName, 'YouTube');
      expect(p.thumbnailUrl, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
      expect(p.kind, LinkKind.youtube);
      expect(p.isVideo, isTrue);
    });

    test('TikTok oEmbed (title is the caption)', () {
      final p = parseTikTokOEmbed({
        'title': 'Praise and worship #gospel',
        'author_name': 'Choir SL',
        'thumbnail_url': 'https://p16-sign.tiktokcdn.com/x.jpeg?expires=1',
        'thumbnail_width': 720,
        'thumbnail_height': 1280,
      }, url: 'https://www.tiktok.com/@choir/video/123');
      expect(p.title, 'Praise and worship #gospel');
      expect(p.author, 'Choir SL');
      expect(p.siteName, 'TikTok');
      expect(p.thumbWidth, 720);
      expect(p.aspectRatio, closeTo(0.5625, 0.001));
    });

    test('Open Graph tags, relative image, entities', () {
      const html = '''<html><head>
        <meta property="og:title" content="God&#39;s Word &amp; You">
        <meta property="og:description" content='A short "teaching".'>
        <meta property="og:image" content="/img/cover.jpg">
        <meta property="og:site_name" content="Truth Blog">
        <title>Ignored</title></head></html>''';
      final p = parseOpenGraph(html, 'https://truth.example.org/posts/1');
      expect(p.title, "God's Word & You");
      expect(p.description, 'A short "teaching".');
      expect(p.thumbnailUrl, 'https://truth.example.org/img/cover.jpg');
      expect(p.siteName, 'Truth Blog');
    });

    test('no Open Graph: <title> and the host', () {
      final p = parseOpenGraph(
          '<html><head><title> Plain page </title></head></html>',
          'https://www.plain.example/x');
      expect(p.title, 'Plain page');
      expect(p.siteName, 'plain.example');
      expect(p.hasThumbnail, isFalse);
    });
  });

  group('LinkPreviewService', () {
    test('YouTube: oEmbed + maxres thumbnail when it exists', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'www.youtube.com') {
          return http.Response(jsonEncode({'title': 'T', 'author_name': 'A'}), 200);
        }
        if (req.method == 'HEAD') return http.Response('', 200);
        return http.Response('', 404);
      });
      final p = await LinkPreviewService(client: client, rehost: (_) async => null)
          .fetch('https://youtu.be/dQw4w9WgXcQ', sharedText: 'Look');
      expect(p.title, 'T');
      expect(p.thumbnailUrl, endsWith('maxresdefault.jpg'));
      expect(p.thumbWidth, 1280);
      expect(p.sharedText, 'Look');
    });

    test('TikTok short link followed, thumbnail re-hosted', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'vm.tiktok.com') {
          return http.Response('', 301,
              headers: {'location': 'https://www.tiktok.com/@c/video/42'});
        }
        if (req.url.path == '/oembed') {
          expect(req.url.queryParameters['url'], 'https://www.tiktok.com/@c/video/42');
          return http.Response(jsonEncode({
            'title': 'Caption',
            'author_name': 'C',
            'thumbnail_url': 'https://cdn.tiktok.example/t.jpg',
          }), 200);
        }
        if (req.url.host == 'cdn.tiktok.example') {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response('', 404);
      });
      final p = await LinkPreviewService(
              client: client,
              rehost: (bytes) async => 'https://res.cloudinary.com/x/thumb.jpg')
          .fetch('https://vm.tiktok.com/ZMabc/');
      expect(p.title, 'Caption');
      expect(p.thumbnailUrl, 'https://res.cloudinary.com/x/thumb.jpg');
    });

    test('everything fails → still a card with link and site', () async {
      final client = MockClient((_) async => throw Exception('offline'));
      final p = await LinkPreviewService(client: client, rehost: (_) async => null)
          .fetch('https://www.bbc.com/news/x');
      expect(p.url, 'https://www.bbc.com/news/x');
      expect(p.siteName, 'bbc.com');
    });
  });

  test('preview survives Firebase / database round trips', () {
    const p = LinkPreview(
        url: 'https://youtu.be/dQw4w9WgXcQ', title: 'T', videoId: 'dQw4w9WgXcQ',
        thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
        thumbWidth: 480, thumbHeight: 360, sharedText: 'hi');
    expect(LinkPreview.fromMap(p.toMap()), p);
    expect(LinkPreview.fromJson(p.toJson()), p);
    final m = PrivateMessage(
        id: 'm', type: 'link', text: 'hi ${p.url}', timestamp: 1,
        senderId: 's', link: p);
    expect(PrivateMessage.fromFirebaseMap('m', m.toFirebaseMap()).link, p);
    expect(PrivateMessage.fromDbMap(m.toDbMap('c')).link, p);
    // Older app versions read only 'text' — the URL is still in it.
    expect(m.toFirebaseMap()['text'], contains(p.url));
  });
}
