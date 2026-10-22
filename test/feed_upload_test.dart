import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/screens/admin_audio_approval_screen.dart';
import 'package:tbtrapp/uploads/feed_upload_service.dart';
import 'package:tbtrapp/util/image_shrink.dart';

void main() {
  group('feedPartText', () {
    test('several files: numbered title and description', () {
      final t = feedPartText(
          title: ' Grace ', description: 'Sunday service', fileName: 'a.mp3',
          part: 2, total: 4);
      expect(t.title, 'Grace — Part 2');
      expect(t.description, '2. Sunday service');
    });

    test('one file: no numbers', () {
      final t = feedPartText(
          title: 'Grace', description: 'Sunday', fileName: 'a.mp3',
          part: 1, total: 1);
      expect(t.title, 'Grace');
      expect(t.description, 'Sunday');
    });

    test('no title: file name without extension; empty description stays empty', () {
      final t = feedPartText(
          title: '  ', description: '', fileName: 'Morning Prayer.m4a',
          part: 3, total: 5);
      expect(t.title, 'Morning Prayer');
      expect(t.description, '');
    });
  });

  test('feedKindForName sorts audio, video and photos; rejects others', () {
    expect(feedKindForName('x.MP3'), FeedMediaKind.audio);
    expect(feedKindForName('x.opus'), FeedMediaKind.audio);
    expect(feedKindForName('x.mkv'), FeedMediaKind.video);
    expect(feedKindForName('x.HEIC'), FeedMediaKind.image);
    expect(feedKindForName('x.pdf'), isNull);
  });

  group('shrinkTarget', () {
    test('landscape photo: longest side becomes the limit', () {
      expect(shrinkTarget(4000, 3000, 1600), (minWidth: 1600, minHeight: 1200));
    });
    test('portrait photo', () {
      expect(shrinkTarget(3000, 4000, 1600), (minWidth: 1200, minHeight: 1600));
    });
    test('already small: left alone', () {
      expect(shrinkTarget(1200, 800, 1600), isNull);
    });
  });

  test('pending list keeps a batch together, in part order', () {
    final items = <Map<String, dynamic>>[
      {'id': 'b3', 'batchId': 'B', 'partNumber': 3, 'timestamp': 30},
      {'id': 'x', 'timestamp': 25},
      {'id': 'b1', 'batchId': 'B', 'partNumber': 1, 'timestamp': 40},
      {'id': 'old', 'timestamp': 5},
      {'id': 'b2', 'batchId': 'B', 'partNumber': 2, 'timestamp': 10},
    ];
    sortPendingForReview(items);
    expect(items.map((m) => m['id']), ['old', 'b1', 'b2', 'b3', 'x']);
  });
}
