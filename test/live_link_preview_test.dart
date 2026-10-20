import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/links/link_preview_service.dart';

/// Real-network check of the preview fetcher (YouTube, TikTok short link,
/// a news site). Not part of the normal run:
///   LIVE_LINKS=1 flutter test test/live_link_preview_test.dart
void main() {
  final skip = !Platform.environment.containsKey('LIVE_LINKS');

  setUpAll(() => HttpOverrides.global = null); // real HTTP, not the test mock

  Future<void> show(String url, {bool needsImage = true}) async {
    final p = await LinkPreviewService(rehost: (_) async => null).fetch(url);
    // ignore: avoid_print
    print('$url\n  title=${p.title}\n  author=${p.author}\n  site=${p.siteName} '
        'video=${p.isVideo} dur=${p.durationSeconds}\n  thumb=${p.thumbnailUrl.isEmpty ? '-' : p.thumbnailUrl} '
        '${p.thumbWidth}x${p.thumbHeight}\n  icon=${p.iconUrl}');
    expect(p.title, isNotEmpty);
    if (needsImage) expect(p.thumbnailUrl, isNotEmpty);
  }

  test('YouTube', () => show('https://youtu.be/dQw4w9WgXcQ'), skip: skip);
  test('YouTube Shorts', () => show('https://www.youtube.com/shorts/aqz-KE-bpKQ'),
      skip: skip);
  test('TikTok video', () => show('https://www.tiktok.com/@scout2015/video/6718335390845095173'),
      skip: skip);
  test('TikTok short link', () => show('https://vm.tiktok.com/ZMSXm2nDC/'), skip: skip);
  test('web page', () => show('https://www.theguardian.com/world', needsImage: false), skip: skip);
}
