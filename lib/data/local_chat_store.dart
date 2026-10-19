import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../data/chat_summary.dart';
import '../data/private_message.dart';

/// The phone's own copy of every conversation — the source of truth for
/// what the chat screens show. Firebase is only a delivery relay: incoming
/// messages are saved here by ChatSyncService (even before the chat is
/// opened), outgoing ones are saved here first and uploaded after.
///
/// Opening a chat reads the newest [pageSize] messages through the
/// (chatId, timestamp) index — or takes them from the in-memory [window]
/// cache with no I/O at all — instead of loading the whole history.
///
/// Schema history (upgrades only ever add; saved chats survive updates):
///  * v2 `waveform`, v3 `listened`;
///  * v4 `status` (pending/sent/delivered), the (chatId, timestamp) index,
///    the local chat list (`chats`) and saved profile photos
///    (`profile_photos`).
///
/// sqflite has no web implementation, so on web this falls back to an
/// in-memory store (lost on refresh).
class LocalChatStore {
  LocalChatStore({DatabaseFactory? factory, String? path})
      : _factory = factory,
        _path = path;

  static LocalChatStore instance = LocalChatStore();

  static const int _dbVersion = 4;

  /// Messages per page when opening a chat / scrolling back.
  static const int pageSize = 50;

  final DatabaseFactory? _factory;
  final String? _path;
  Future<Database>? _opening;

  // In-memory fallback, used only when kIsWeb.
  final Map<String, List<PrivateMessage>> _memStore = {};
  final Map<String, ChatSummary> _memChats = {};
  final Map<String, String> _memPhotos = {};

  bool get _inMemory => kIsWeb && _factory == null;

  Future<Database> get _database => _opening ??= _open();

  Future<Database> _open() async {
    final factory = _factory ?? databaseFactory;
    final path = _path ?? join(await factory.getDatabasesPath(), 'local_chat_store.db');
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE messages (
              id TEXT NOT NULL,
              chatId TEXT NOT NULL,
              text TEXT NOT NULL,
              type TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              senderId TEXT NOT NULL,
              senderName TEXT NOT NULL,
              senderPhone TEXT NOT NULL,
              replyToId TEXT NOT NULL,
              replyToText TEXT NOT NULL,
              replyToSenderName TEXT NOT NULL,
              stickerId TEXT NOT NULL,
              audioUrl TEXT NOT NULL,
              duration INTEGER NOT NULL,
              fileUrl TEXT NOT NULL,
              fileName TEXT NOT NULL,
              mimeType TEXT NOT NULL,
              waveform TEXT NOT NULL DEFAULT '',
              listened INTEGER NOT NULL DEFAULT 0,
              status INTEGER NOT NULL DEFAULT 1,
              PRIMARY KEY (id, chatId)
            )
          ''');
          await db.execute('CREATE INDEX idx_messages_chatId ON messages(chatId)');
          await _createV4Extras(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "ALTER TABLE messages ADD COLUMN waveform TEXT NOT NULL DEFAULT ''",
            );
          }
          if (oldVersion < 3) {
            // Everything saved before v3 had already been seen in the old
            // UI, so it starts as listened.
            await db.execute(
              'ALTER TABLE messages ADD COLUMN listened INTEGER NOT NULL DEFAULT 1',
            );
          }
          if (oldVersion < 4) {
            // Everything saved before v4 was already on the server.
            await db.execute(
              'ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 1',
            );
            await _createV4Extras(db);
          }
        },
      ),
    );
  }

  static Future<void> _createV4Extras(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_chat_ts ON messages(chatId, timestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chats (
        chatId TEXT PRIMARY KEY,
        otherUid TEXT NOT NULL,
        otherName TEXT NOT NULL,
        lastMessage TEXT NOT NULL,
        lastTimestamp INTEGER NOT NULL,
        unread INTEGER NOT NULL,
        lastReadTimestamp INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS profile_photos (
        uid TEXT PRIMARY KEY,
        photo TEXT NOT NULL,
        savedAt INTEGER NOT NULL
      )
    ''');
  }

  // ── change notifications ────────────────────────────────────────────

  final StreamController<String> _changes = StreamController.broadcast();
  final Set<String> _dirty = {};
  bool _flushScheduled = false;

  /// Emits a chat id whenever that chat's local messages changed. Bursts
  /// (a batch of relay messages) are coalesced into one event per chat.
  Stream<String> get changes => _changes.stream;

  void _markDirty(String chatId) {
    _windows.remove(chatId);
    _dirty.add(chatId);
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      final ids = _dirty.toList();
      _dirty.clear();
      for (final id in ids) {
        _changes.add(id);
      }
    });
  }

  // ── in-memory window cache ──────────────────────────────────────────

  final Map<String, List<PrivateMessage>> _windows = {};

  /// The newest messages of [chatId] from the last read, if still valid —
  /// lets a chat render on its very first frame without touching disk.
  List<PrivateMessage>? window(String chatId) => _windows[chatId];

  void _remember(String chatId, List<PrivateMessage> msgs) {
    _windows.remove(chatId);
    _windows[chatId] = List.unmodifiable(msgs);
    while (_windows.length > 30) {
      _windows.remove(_windows.keys.first);
    }
  }

  // ── reads ───────────────────────────────────────────────────────────

  /// The newest [limit] messages, oldest first.
  Future<List<PrivateMessage>> latest(String chatId,
      {int limit = pageSize}) async {
    if (_inMemory) {
      final all = _memStore[chatId] ?? const [];
      final out = all.length <= limit ? List.of(all) : all.sublist(all.length - limit);
      _remember(chatId, out);
      return out;
    }
    final db = await _database;
    final rows = await db.query('messages',
        where: 'chatId = ?',
        whereArgs: [chatId],
        orderBy: 'timestamp DESC, id DESC',
        limit: limit);
    final out = rows.reversed.map(PrivateMessage.fromDbMap).toList();
    if (limit >= pageSize) _remember(chatId, out);
    return out;
  }

  /// Every message at or after [sinceTimestamp], oldest first — the window
  /// a chat screen has loaded, re-read after a change.
  Future<List<PrivateMessage>> since(String chatId, int sinceTimestamp) async {
    if (_inMemory) {
      return (_memStore[chatId] ?? const [])
          .where((m) => m.timestamp >= sinceTimestamp)
          .toList();
    }
    final db = await _database;
    final rows = await db.query('messages',
        where: 'chatId = ? AND timestamp >= ?',
        whereArgs: [chatId, sinceTimestamp],
        orderBy: 'timestamp ASC, id ASC');
    final out = rows.map(PrivateMessage.fromDbMap).toList();
    if (out.length <= pageSize * 2) {
      _remember(chatId, out.length > pageSize ? out.sublist(out.length - pageSize) : out);
    }
    return out;
  }

  /// Up to [limit] messages older than [beforeTimestamp], oldest first.
  Future<List<PrivateMessage>> olderThan(String chatId, int beforeTimestamp,
      {int limit = pageSize}) async {
    if (_inMemory) {
      final older = (_memStore[chatId] ?? const [])
          .where((m) => m.timestamp < beforeTimestamp)
          .toList();
      return older.length <= limit ? older : older.sublist(older.length - limit);
    }
    final db = await _database;
    final rows = await db.query('messages',
        where: 'chatId = ? AND timestamp < ?',
        whereArgs: [chatId, beforeTimestamp],
        orderBy: 'timestamp DESC, id DESC',
        limit: limit);
    return rows.reversed.map(PrivateMessage.fromDbMap).toList();
  }

  Future<int> count(String chatId) async {
    if (_inMemory) return _memStore[chatId]?.length ?? 0;
    final db = await _database;
    return Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM messages WHERE chatId = ?', [chatId])) ??
        0;
  }

  /// My messages that never reached the server (sent offline, app closed).
  Future<List<({String chatId, PrivateMessage message})>> pendingOutgoing(
      String myUid) async {
    if (_inMemory) {
      return [
        for (final e in _memStore.entries)
          for (final m in e.value)
            if (m.status == MessageStatus.pending && m.senderId == myUid)
              (chatId: e.key, message: m),
      ];
    }
    final db = await _database;
    final rows = await db.query('messages',
        where: 'status = ? AND senderId = ?',
        whereArgs: [MessageStatus.pending, myUid],
        orderBy: 'timestamp ASC');
    return [
      for (final r in rows)
        (chatId: r['chatId'] as String, message: PrivateMessage.fromDbMap(r)),
    ];
  }

  // ── writes ──────────────────────────────────────────────────────────

  /// Saves a message I just created (or replaces a local one).
  Future<void> insert(String chatId, PrivateMessage message) async {
    if (_inMemory) {
      _memUpsert(chatId, [message], replace: true);
      _markDirty(chatId);
      return;
    }
    final db = await _database;
    await db.insert('messages', message.toDbMap(chatId),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _markDirty(chatId);
  }

  /// Saves messages that arrived from the relay in one transaction. Ones
  /// already on the phone are left as they are, so local state (listened,
  /// delivery status) is kept. Returns how many were new.
  Future<int> insertIncoming(String chatId, List<PrivateMessage> messages) async {
    if (messages.isEmpty) return 0;
    if (_inMemory) {
      final n = _memUpsert(chatId, messages, replace: false);
      if (n > 0) _markDirty(chatId);
      return n;
    }
    final db = await _database;
    var added = 0;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in messages) {
        batch.insert('messages', m.toDbMap(chatId),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final r in await batch.commit()) {
        if (r is int && r > 0) added++;
      }
    });
    if (added > 0) _markDirty(chatId);
    return added;
  }

  int _memUpsert(String chatId, List<PrivateMessage> msgs,
      {required bool replace}) {
    final list = _memStore.putIfAbsent(chatId, () => []);
    var added = 0;
    for (final m in msgs) {
      final i = list.indexWhere((x) => x.id == m.id);
      if (i == -1) {
        list.add(m);
        added++;
      } else if (replace) {
        list[i] = m;
      }
    }
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return added;
  }

  /// Moves one of my messages forward to [status] (never backwards).
  Future<void> setStatus(String chatId, String messageId, int status) async {
    if (_inMemory) {
      final list = _memStore[chatId];
      final i = list?.indexWhere((m) => m.id == messageId) ?? -1;
      if (i == -1 || list![i].status >= status) return;
      list[i] = list[i].copyWith(status: status);
      _markDirty(chatId);
      return;
    }
    final db = await _database;
    final n = await db.update('messages', {'status': status},
        where: 'id = ? AND chatId = ? AND status < ?',
        whereArgs: [messageId, chatId, status]);
    if (n > 0) _markDirty(chatId);
  }

  /// Deletes one message from this device only ("delete for me"). Does
  /// not touch Firebase — the relay node is already gone for delivered
  /// messages, and other participants keep their own local copies.
  Future<void> deleteForMe(String chatId, String messageId) async {
    if (_inMemory) {
      _memStore[chatId]?.removeWhere((m) => m.id == messageId);
      _markDirty(chatId);
      return;
    }
    final db = await _database;
    await db.delete('messages',
        where: 'id = ? AND chatId = ?', whereArgs: [messageId, chatId]);
    _markDirty(chatId);
  }

  /// Marks a single message as listened/read (voice note played).
  Future<void> markListened(String chatId, String messageId) async {
    if (_inMemory) {
      final list = _memStore[chatId];
      if (list == null) return;
      final idx = list.indexWhere((m) => m.id == messageId);
      if (idx == -1 || list[idx].listened) return;
      list[idx] = list[idx].copyWith(listened: true);
      _markDirty(chatId);
      return;
    }
    final db = await _database;
    final updated = await db.update('messages', {'listened': 1},
        where: 'id = ? AND chatId = ? AND listened = 0',
        whereArgs: [messageId, chatId]);
    if (updated > 0) _markDirty(chatId);
  }

  /// Marks every message in a chat as listened.
  Future<void> markAllListened(String chatId) async {
    if (_inMemory) {
      final list = _memStore[chatId];
      if (list == null) return;
      var changed = false;
      for (var i = 0; i < list.length; i++) {
        if (!list[i].listened) {
          list[i] = list[i].copyWith(listened: true);
          changed = true;
        }
      }
      if (changed) _markDirty(chatId);
      return;
    }
    final db = await _database;
    final updated = await db.update('messages', {'listened': 1},
        where: 'chatId = ? AND listened = 0', whereArgs: [chatId]);
    if (updated > 0) _markDirty(chatId);
  }

  /// Re-keys local history after an account id changed from [oldUid] to
  /// [newUid] (AccountSelfRepair): chat ids are built from both
  /// participants' ids, so every conversation of the old id moves to the
  /// new chat id, and the user's own messages get the new sender id.
  Future<void> renameUser(String oldUid, String newUid) async {
    if (_inMemory || oldUid == newUid) return;
    final db = await _database;
    final rows = await db.rawQuery(
        'SELECT DISTINCT chatId FROM messages WHERE chatId LIKE ? OR chatId LIKE ?',
        ['${oldUid}_%', '%_$oldUid']);
    final touched = <String>{};
    await db.transaction((txn) async {
      for (final r in rows) {
        final oldCid = r['chatId'] as String;
        final parts = oldCid.split('_');
        if (parts.length != 2 || !parts.contains(oldUid)) continue;
        final other = parts[0] == oldUid ? parts[1] : parts[0];
        final ids = [newUid, other == oldUid ? newUid : other]..sort();
        final newCid = ids.join('_');
        await txn.rawUpdate(
            'UPDATE OR IGNORE messages SET chatId = ? WHERE chatId = ?',
            [newCid, oldCid]);
        await txn.delete('messages', where: 'chatId = ?', whereArgs: [oldCid]);
        touched..add(oldCid)..add(newCid);
      }
      await txn.rawUpdate('UPDATE messages SET senderId = ? WHERE senderId = ?',
          [newUid, oldUid]);
      await txn.delete('chats');
    });
    touched.forEach(_markDirty);
    _chatsChanged.add(null);
  }

  // ── local chat list (Discussions) ──────────────────────────────────

  final StreamController<void> _chatsChanged = StreamController.broadcast();
  Stream<void> get chatsChanged => _chatsChanged.stream;

  List<ChatSummary>? _chatsCache;

  /// Last known chat list from memory, if already read this session.
  List<ChatSummary>? get cachedChats => _chatsCache;

  Future<List<ChatSummary>> chats() async {
    if (_inMemory) return _chatsCache = _memChats.values.toList();
    final db = await _database;
    final rows = await db.query('chats', orderBy: 'lastTimestamp DESC');
    return _chatsCache = [
      for (final r in rows)
        ChatSummary(
          chatId: r['chatId'] as String,
          otherUid: r['otherUid'] as String,
          otherName: r['otherName'] as String,
          otherPhotoUrl: '',
          lastMessage: r['lastMessage'] as String,
          lastTimestamp: r['lastTimestamp'] as int,
          unread: r['unread'] as int,
          lastReadTimestamp: r['lastReadTimestamp'] as int,
        ),
    ];
  }

  /// Replaces the local chat list with the server's `userChats/{me}`.
  Future<void> replaceChats(List<ChatSummary> list) async {
    if (_inMemory) {
      _memChats
        ..clear()
        ..addEntries(list.map((c) => MapEntry(c.chatId, c)));
    } else {
      final db = await _database;
      await db.transaction((txn) async {
        await txn.delete('chats');
        final batch = txn.batch();
        for (final c in list) {
          batch.insert('chats', {
            'chatId': c.chatId,
            'otherUid': c.otherUid,
            'otherName': c.otherName,
            'lastMessage': c.lastMessage,
            'lastTimestamp': c.lastTimestamp,
            'unread': c.unread,
            'lastReadTimestamp': c.lastReadTimestamp,
          });
        }
        await batch.commit(noResult: true);
      });
    }
    _chatsCache = List.of(list)
      ..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));
    _chatsChanged.add(null);
  }

  // ── saved profile photos ───────────────────────────────────────────

  Future<Map<String, String>> allPhotos() async {
    if (_inMemory) return Map.of(_memPhotos);
    final db = await _database;
    final rows = await db.query('profile_photos');
    return {for (final r in rows) r['uid'] as String: r['photo'] as String};
  }

  Future<void> savePhoto(String uid, String photo) async {
    if (_inMemory) {
      _memPhotos[uid] = photo;
      return;
    }
    final db = await _database;
    await db.insert(
        'profile_photos',
        {'uid': uid, 'photo': photo, 'savedAt': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @visibleForTesting
  Future<void> close() async {
    final db = await _opening;
    await db?.close();
    _opening = null;
  }
}
