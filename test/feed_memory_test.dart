import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tbtrapp/data/feed_item.dart';
import 'package:tbtrapp/data/local_feed_store.dart';
import 'package:tbtrapp/data/sermon_audio.dart';
import 'package:tbtrapp/data/text_message.dart';
import 'package:tbtrapp/links/link_preview.dart';
import 'package:tbtrapp/screens/audio/audio_feed_provider.dart';

FeedItem _post(String id, int ts, {String sender = '+23276000002'}) =>
    FeedItem.fromTextMessage(TextMessage(
        id: id, text: 'post $id', timestamp: ts, senderId: sender,
        senderName: '', senderPhone: sender));

void main() {
  // 10 posts, oldest first, timestamps 1000..10000.
  final items = [for (var i = 1; i <= 10; i++) _post('p$i', i * 1000)];

  group('where the Audio screen opens', () {
    test('first time (nothing saved) → newest post', () {
      final s = initialFeedScroll(items, null);
      expect(s.index, 0);
      expect(s.alignment, 0);
    });

    test('left at the newest → newest again', () {
      final s = initialFeedScroll(items, const FeedPosition(
          itemId: 'p10', itemTimestamp: 10000, alignment: 0, atNewest: true));
      expect(s.index, 0);
    });

    test('left in the middle → exactly that post and offset', () {
      final s = initialFeedScroll(items, const FeedPosition(
          itemId: 'p4', itemTimestamp: 4000, alignment: 0.35, atNewest: false));
      // Reversed list: p10 is 0, p4 is 6.
      expect(s.index, 6);
      expect(s.alignment, 0.35);
    });

    test('new posts arrived since → still the same post', () {
      final more = [...items, _post('p11', 11000), _post('p12', 12000)];
      final s = initialFeedScroll(more, const FeedPosition(
          itemId: 'p4', itemTimestamp: 4000, alignment: 0.35, atNewest: false));
      expect(more[more.length - 1 - s.index].id, 'p4');
    });

    test('saved post was deleted → the nearest older one', () {
      final without = items.where((f) => f.id != 'p4').toList();
      final s = initialFeedScroll(without, const FeedPosition(
          itemId: 'p4', itemTimestamp: 4000, alignment: 0.2, atNewest: false));
      expect(without[without.length - 1 - s.index].id, 'p3');
    });
  });

  group('"N new messages" divider', () {
    test('above the first post newer than the last one read', () {
      final d = unreadDivider(items, 7000);
      expect(d.firstUnreadId, 'p8');
      expect(d.count, 3);
    });

    test('nothing new → no divider', () {
      final d = unreadDivider(items, 10000);
      expect(d.firstUnreadId, isNull);
      expect(d.count, 0);
    });

    test('first install (nothing read yet) → no divider', () {
      expect(unreadDivider(items, 0).firstUnreadId, isNull);
    });

    test('my own new posts are not "new messages"', () {
      final mine = [...items, _post('m1', 11000, sender: '+23276000001')];
      final d = unreadDivider(mine, 10000, myUid: '+23276000001');
      expect(d.count, 0);
    });
  });

  group('LocalFeedStore', () {
    sqfliteFfiInit();
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('feedstore'));
    tearDown(() async => dir.delete(recursive: true));

    test('upgrade from v1 keeps every cached post and adds link previews',
        () async {
      final path = '${dir.path}/feed.db';
      final v1 = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 1,
              onCreate: (db, _) async {
                await db.execute('''CREATE TABLE sermons (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                  description TEXT NOT NULL DEFAULT '', audioUrl TEXT NOT NULL DEFAULT '',
                  mediaType TEXT NOT NULL DEFAULT 'AUDIO', senderId TEXT NOT NULL DEFAULT '',
                  senderName TEXT NOT NULL DEFAULT '', timestamp INTEGER NOT NULL DEFAULT 0)''');
                await db.execute('''CREATE TABLE feed_texts (
                  id TEXT PRIMARY KEY, text TEXT NOT NULL DEFAULT '',
                  timestamp INTEGER NOT NULL DEFAULT 0, replyToId TEXT NOT NULL DEFAULT '',
                  replyToType TEXT NOT NULL DEFAULT '', replyToPreview TEXT NOT NULL DEFAULT '',
                  senderId TEXT NOT NULL DEFAULT '', senderName TEXT NOT NULL DEFAULT '',
                  senderPhone TEXT NOT NULL DEFAULT '')''');
                await db.execute('''CREATE TABLE feed_reactions (
                  itemId TEXT NOT NULL, emoji TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (itemId, emoji))''');
              }));
      await v1.insert('sermons', {
        'id': 's1', 'title': 'Old sermon', 'audioUrl': 'https://x/a.mp3',
        'timestamp': 5000,
      });
      await v1.insert('feed_texts', {'id': 't1', 'text': 'hello', 'timestamp': 6000});
      await v1.close();

      final store = LocalFeedStore(factory: databaseFactoryFfi, path: path);
      final all = await store.loadAll();
      expect(all.sermons.single.title, 'Old sermon');
      expect(all.texts.single.text, 'hello');
      expect(await store.latestTimestamp(), 6000);

      const link = LinkPreview(
          url: 'https://youtu.be/dQw4w9WgXcQ', title: 'A video',
          siteName: 'YouTube', videoId: 'dQw4w9WgXcQ');
      await store.upsertSermons([
        SermonAudio(id: 's2', title: 'Shared', audioUrl: '', mediaType: 'LINK',
            senderId: 'x', senderName: '', timestamp: 7000, link: link),
      ]);
      final again = await store.loadAll();
      final shared = again.sermons.firstWhere((s) => s.id == 's2');
      expect(shared.isLink, isTrue);
      expect(shared.link, link);
      expect(await store.latestTimestamp(), 7000);

      await store.setItemReactions('s1', {'❤️': 2});
      await store.close();
    });

    test('open timing: 600 stored posts read for the first frame', () async {
      final store =
          LocalFeedStore(factory: databaseFactoryFfi, path: '${dir.path}/b.db');
      await store.upsertSermons([
        for (var i = 0; i < 200; i++)
          SermonAudio(
              id: 's$i', title: 'Sermon $i', description: 'd' * 160,
              audioUrl: 'https://res.cloudinary.com/x/s$i.mp3',
              mediaType: 'AUDIO', senderId: '+23276000002', senderName: '',
              timestamp: i * 1000),
      ]);
      await store.upsertTexts([
        for (var i = 0; i < 400; i++)
          TextMessage(
              id: 't$i', text: 'message number $i ' * 3, timestamp: i * 1000 + 500,
              senderId: '+23276000003', senderName: '', senderPhone: ''),
      ]);
      final sw = Stopwatch()..start();
      final all = await store.loadAll();
      final items = buildFeedItems(all.sermons, all.texts);
      final start = initialFeedScroll(items, null);
      final ms = sw.elapsedMicroseconds / 1000;
      // ignore: avoid_print
      print('FEED OPEN: ${items.length} posts read + ordered in '
          '${ms.toStringAsFixed(1)} ms (local, no network)');
      expect(items, hasLength(600));
      expect(start.index, 0);
      await store.close();
    });
  });
}
