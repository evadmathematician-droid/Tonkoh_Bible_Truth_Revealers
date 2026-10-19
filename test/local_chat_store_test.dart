import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tbtrapp/data/chat_summary.dart';
import 'package:tbtrapp/data/local_chat_store.dart';
import 'package:tbtrapp/data/private_message.dart';

/// LocalChatStore on real SQLite (FFI): paging, outbox, upgrade from the
/// v3 database that phones have today, and the open-chat timing of a long
/// conversation (old full load vs. the new newest-page read).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late LocalChatStore store;
  const cid = '+23231932652_+23288236249';

  PrivateMessage msg(int i, {String sender = '+23288236249', int status = 1}) =>
      PrivateMessage(
        id: 'm${i.toString().padLeft(5, '0')}',
        text: 'message $i',
        timestamp: 1700000000000 + i * 1000,
        senderId: sender,
        status: status,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chatstore');
    store = LocalChatStore(
        factory: databaseFactoryFfi, path: '${dir.path}/chat.db');
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('newest page first, older pages on demand, oldest first', () async {
    await store.insertIncoming(cid, [for (var i = 0; i < 130; i++) msg(i)]);
    final first = await store.latest(cid);
    expect(first, hasLength(LocalChatStore.pageSize));
    expect(first.first.id, 'm00080');
    expect(first.last.id, 'm00129');
    final older = await store.olderThan(cid, first.first.timestamp);
    expect(older.first.id, 'm00030');
    expect(older.last.id, 'm00079');
    final oldest = await store.olderThan(cid, older.first.timestamp);
    expect(oldest, hasLength(30));
    expect(await store.count(cid), 130);
  });

  test('window cache is filled by a read and dropped by a change', () async {
    await store.insertIncoming(cid, [for (var i = 0; i < 10; i++) msg(i)]);
    await store.latest(cid);
    expect(store.window(cid), hasLength(10));
    final changed = store.changes.first;
    await store.insert(cid, msg(10));
    expect(await changed, cid);
    expect(store.window(cid), isNull);
  });

  test('incoming duplicates keep local state; bursts notify once', () async {
    await store.insert(cid, msg(1).copyWith(listened: true));
    await Future<void>.delayed(Duration.zero); // let that change notify
    var events = 0;
    final sub = store.changes.listen((_) => events++);
    final added = await store.insertIncoming(cid, [msg(1), msg(2), msg(3)]);
    await Future<void>.delayed(Duration.zero);
    expect(added, 2);
    expect(events, 1);
    final all = await store.latest(cid);
    expect(all.firstWhere((m) => m.id == 'm00001').listened, isTrue);
    await sub.cancel();
  });

  test('outbox: pending → sent → delivered, never backwards', () async {
    const me = '+23231932652';
    await store.insert(cid, msg(1, sender: me, status: MessageStatus.pending));
    await store.insert(cid, msg(2, sender: me, status: MessageStatus.sent));
    final pending = await store.pendingOutgoing(me);
    expect(pending.map((p) => p.message.id), ['m00001']);
    await store.setStatus(cid, 'm00001', MessageStatus.delivered);
    await store.setStatus(cid, 'm00001', MessageStatus.sent);
    final m = (await store.latest(cid)).firstWhere((m) => m.id == 'm00001');
    expect(m.status, MessageStatus.delivered);
    expect(await store.pendingOutgoing(me), isEmpty);
  });

  test('local chat list round-trips', () async {
    await store.replaceChats(const [
      ChatSummary(
          chatId: cid,
          otherUid: '+23288236249',
          otherName: 'Prof',
          otherPhotoUrl: '',
          lastMessage: 'hi',
          lastTimestamp: 5,
          unread: 2,
          lastReadTimestamp: 1),
    ]);
    final chats = await store.chats();
    expect(chats.single.unread, 2);
    expect(store.cachedChats, isNotNull);
  });

  test('renameUser re-keys chats and my sender id', () async {
    const oldMe = '+031932652';
    const oldCid = '+031932652_+23288236249';
    await store.insert(oldCid, msg(1, sender: oldMe));
    await store.renameUser(oldMe, '+23231932652');
    final moved = await store.latest(cid);
    expect(moved.single.senderId, '+23231932652');
    expect(await store.count(oldCid), 0);
  });

  test('upgrade from the v3 database phones have now keeps every message',
      () async {
    final path = '${dir.path}/legacy.db';
    final v3 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, _) async {
              await db.execute('''
                CREATE TABLE messages (
                  id TEXT NOT NULL, chatId TEXT NOT NULL, text TEXT NOT NULL,
                  type TEXT NOT NULL, timestamp INTEGER NOT NULL,
                  senderId TEXT NOT NULL, senderName TEXT NOT NULL,
                  senderPhone TEXT NOT NULL, replyToId TEXT NOT NULL,
                  replyToText TEXT NOT NULL, replyToSenderName TEXT NOT NULL,
                  stickerId TEXT NOT NULL, audioUrl TEXT NOT NULL,
                  duration INTEGER NOT NULL, fileUrl TEXT NOT NULL,
                  fileName TEXT NOT NULL, mimeType TEXT NOT NULL,
                  waveform TEXT NOT NULL DEFAULT '',
                  listened INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (id, chatId))''');
              await db.execute(
                  'CREATE INDEX idx_messages_chatId ON messages(chatId)');
            }));
    for (var i = 0; i < 25; i++) {
      final row = msg(i).toDbMap(cid)
        ..remove('status')
        ..remove('linkJson');
      await v3.insert('messages', row);
    }
    await v3.close();

    final upgraded = LocalChatStore(factory: databaseFactoryFfi, path: path);
    final all = await upgraded.latest(cid);
    expect(all, hasLength(25));
    expect(all.every((m) => m.status == MessageStatus.sent), isTrue);
    expect(await upgraded.pendingOutgoing('+23288236249'), isEmpty);
    await upgraded.replaceChats(const []); // new table exists
    await upgraded.close();
  });

  test('open-chat timing on a 1200-message conversation', () async {
    // Realistic mix: mostly text, every 10th a ~60 KB base64 voice note,
    // every 25th a ~120 KB base64 photo (older app versions stored media
    // inline).
    final rng = Random(1);
    String blob(int bytes) =>
        base64Encode(List<int>.generate(bytes, (_) => rng.nextInt(256)));
    final voice = blob(45000), photo = blob(90000);
    final msgs = [
      for (var i = 0; i < 1200; i++)
        msg(i).copyWith(
          type: i % 10 == 0 ? 'voice' : (i % 25 == 0 ? 'image' : 'text'),
          audioUrl: i % 10 == 0 ? voice : '',
          fileUrl: i % 25 == 0 ? photo : '',
        ),
    ];
    for (var i = 0; i < msgs.length; i += 200) {
      await store.insertIncoming(cid, msgs.sublist(i, i + 200));
    }
    // Same database for both paths; open it once first.
    await store.count(cid);
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/chat.db');

    // OLD path (before this change): every message of the chat, full rows,
    // ordered by timestamp — what the chat screen loaded on open (and again
    // after every relay message that arrived).
    final sw = Stopwatch()..start();
    final rows = await db.query('messages',
        where: 'chatId = ?', whereArgs: [cid], orderBy: 'timestamp ASC');
    final oldList = rows.map(PrivateMessage.fromDbMap).toList();
    final oldMs = sw.elapsedMicroseconds / 1000;

    // NEW path: newest page through the (chatId, timestamp) index.
    sw.reset();
    final page = await store.latest(cid);
    final newMs = sw.elapsedMicroseconds / 1000;

    // Reopening: the in-memory window, no I/O.
    sw.reset();
    final again = store.window(cid);
    final reopenMs = sw.elapsedMicroseconds / 1000;
    await db.close();

    // ignore: avoid_print
    print('OPEN 1200 msgs: old full load ${oldMs.toStringAsFixed(1)} ms '
        '(${oldList.length} rows), new first page ${newMs.toStringAsFixed(1)} ms '
        '(${page.length} rows), reopen from memory '
        '${reopenMs.toStringAsFixed(3)} ms');
    expect(page, hasLength(LocalChatStore.pageSize));
    expect(again, isNotNull);
    expect(newMs, lessThan(oldMs));
  });
}
