import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tbtrapp/links/link_preview.dart';
import 'package:tbtrapp/links/link_preview_cache.dart';
import 'package:tbtrapp/links/link_preview_card.dart';
import 'package:tbtrapp/links/link_preview_service.dart';
import 'package:tbtrapp/links/tiktok_page.dart';

/// Parsing from pages saved from the real sites (test/fixtures), the
/// per-phone cache, and the card's fallback look.
void main() {
  const tiktokUrl =
      'https://www.tiktok.com/@scout2015/video/6718335390845095173';
  String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LinkPreviewCache.instance.debugClear();
  });

  group('TikTok', () {
    test('video id from the URL forms', () {
      expect(tiktokVideoId(tiktokUrl), '6718335390845095173');
      expect(tiktokVideoId('https://m.tiktok.com/v/6718335390845095173.html'),
          '6718335390845095173');
      expect(tiktokVideoId('https://www.tiktok.com/@a'), isNull);
    });

    test('video page data: caption, author, vertical cover, duration', () {
      final info = parseTikTokPage(fixture('tiktok_video_page.html'))!;
      expect(info.caption, startsWith('Scramble up ur name'));
      expect(info.author, 'Scout, Suki & Stella');
      expect(info.width, 576);
      expect(info.height, 1024);
      expect(info.durationSeconds, 10);

      final p = tiktokPreviewFromPage(info, tiktokUrl);
      expect(p.isVideo, isTrue);
      expect(p.siteName, 'TikTok');
      expect(p.hasThumbnail, isTrue);
      expect(p.aspectRatio, lessThan(1)); // vertical
      expect(p.durationSeconds, 10);
    });

    test('a page without video data is not mistaken for one', () {
      expect(parseTikTokPage('<html><body>Please wait…</body></html>'), isNull);
    });

    test('crawler page Open Graph tags give thumbnail and author', () {
      final p = parseOpenGraph(fixture('tiktok_crawler_page.html'), tiktokUrl);
      expect(p.title, contains('Scout, Suki & Stella'));
      expect(
          p.thumbnailUrl, startsWith('https://p16-common-sign.tiktokcdn.com/'));
      expect(p.thumbnailUrl, isNot(contains('&amp;')));
    });
  });

  group('Open Graph extras', () {
    test('favicon, og:video and duration-less video', () {
      const html = '''
<html><head>
<meta property="og:title" content="Clip">
<meta property="og:type" content="video.other">
<meta property="og:video" content="https://cdn.example.com/v.mp4">
<meta property="og:image" content="/img/c.jpg">
<link rel="icon" href="/favicon.ico">
</head></html>''';
      final p = parseOpenGraph(html, 'https://news.example.com/a/b');
      expect(p.title, 'Clip');
      expect(p.isVideo, isTrue);
      expect(p.thumbnailUrl, 'https://news.example.com/img/c.jpg');
      expect(p.iconUrl, 'https://news.example.com/favicon.ico');
    });

    test('new fields survive the database round trip', () {
      const p = LinkPreview(
          url: tiktokUrl,
          title: 'T',
          durationSeconds: 10,
          iconUrl: 'https://x/i.png',
          video: true);
      final back = LinkPreview.fromMap(p.toMap())!;
      expect(back, p);
      expect(back.durationSeconds, 10);
      expect(back.iconUrl, 'https://x/i.png');
    });

    test('old messages without the new fields still read', () {
      final p =
          LinkPreview.fromMap({'url': 'https://example.com', 'title': 'T'});
      expect(p!.durationSeconds, 0);
      expect(p.iconUrl, '');
      expect(LinkPreview.fromMap({'type': 'link'}), isNull);
    });
  });

  group('preview cache', () {
    test('second fetch of the same link is served from the cache', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
            '<meta property="og:title" content="Cached page">', 200,
            headers: {'content-type': 'text/html'});
      });
      final service = LinkPreviewService(
          client: client,
          rehost: (_) async => null,
          cache: LinkPreviewCache.instance);
      const url = 'https://example.org/page';
      final first = await service.fetch(url);
      expect(first.title, 'Cached page');
      final used = calls;
      expect(service.cached(url)?.title, 'Cached page');
      final second = await service.fetch(url);
      expect(second.title, 'Cached page');
      expect(calls, used);
    });

    test('keeps only the most recent entries', () async {
      final cache = LinkPreviewCache.instance;
      for (var i = 0; i < LinkPreviewCache.maxEntries + 5; i++) {
        await cache.put(
            'https://e.com/$i', LinkPreview(url: 'https://e.com/$i'));
      }
      expect(cache.peek('https://e.com/0'), isNull);
      expect(cache.peek('https://e.com/${LinkPreviewCache.maxEntries + 4}'),
          isNotNull);
    });

    test('failed fetches are not cached', () async {
      final service = LinkPreviewService(
          client: MockClient((_) async => throw Exception('offline')),
          rehost: (_) async => null,
          cache: LinkPreviewCache.instance);
      await service.fetch('https://down.example.com/x');
      expect(service.cached('https://down.example.com/x'), isNull);
    });
  });

  group('card', () {
    Widget host(Widget child) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SizedBox(width: 360, child: child))));

    testWidgets('fallback card: no thumbnail, still site and link',
        (tester) async {
      await tester.pumpWidget(host(LinkPreviewCard(
          preview: LinkPreview.basic('https://www.bbc.com/news/x'),
          onTap: () {})));
      expect(find.text('bbc.com'), findsOneWidget);
      expect(find.text('bbc.com/news/x'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('vertical video thumbnail is capped and shows ▶ + duration',
        (tester) async {
      await tester.pumpWidget(host(LinkPreviewCard(
        onTap: () {},
        preview: const LinkPreview(
          url: tiktokUrl,
          title: 'Caption',
          thumbnailUrl: 'https://res.cloudinary.com/x/c.jpg',
          thumbWidth: 576,
          thumbHeight: 1024,
          durationSeconds: 75,
        ),
      )));
      final box = tester.getSize(find
          .ancestor(
              of: find.byIcon(Icons.play_arrow_rounded),
              matching: find.byType(Stack))
          .first);
      expect(box.height, kLinkThumbMaxHeight);
      expect(find.text('1:15'), findsOneWidget);
    });

    testWidgets('long description collapses to 3 lines with "more"',
        (tester) async {
      await tester.pumpWidget(host(LinkPreviewCard(
        onTap: () {},
        preview: LinkPreview(
            url: 'https://example.com', title: 'T', description: 'word ' * 200),
      )));
      expect(find.text('more'), findsOneWidget);
      await tester.tap(find.text('more'));
      await tester.pump();
      expect(find.text('less'), findsOneWidget);
    });

    test('duration and short link labels', () {
      expect(formatDuration(7), '0:07');
      expect(formatDuration(3725), '1:02:05');
      expect(shortLinkLabel('https://www.example.com/'), 'example.com');
    });
  });
}
