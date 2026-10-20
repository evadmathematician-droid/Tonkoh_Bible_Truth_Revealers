import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'sermon_audio.dart';
import 'text_message.dart';

/// On-device cache for the audio discussion feed — the sermons/media items
/// and the feed text-posts shown on `AudioScreen`, plus their reaction
/// counts.
///
/// This is the single source of truth the UI renders from (via
/// `AudioFeedProvider`). Firebase RTDB (`sermons/approved`, `textMessages`,
/// `reactions`) is only a sync source: `AudioFeedProvider` upserts every
/// incoming node here, and the UI updates reactively from these streams —
/// never straight from the Firebase snapshot. So the feed stays fully
/// readable with no connectivity; only *new* items need the network.
///
/// Deliberately upsert-only for `sermons` / `feed_texts`: an absent node
/// (offline, or one that scrolled out of `limitToLast`) must never delete
/// local history. Rows go away only through [deleteSermon] / [deleteText],
/// which `AudioFeedProvider.deleteItem` calls on an explicit admin delete.
///
/// Mirrors `LocalChatStore`: sqflite everywhere except web, which has no
/// sqflite implementation and falls back to an in-memory store (lost on
/// refresh).
class LocalFeedStore {
  LocalFeedStore({DatabaseFactory? factory, String? path})
      : _factory = factory,
        _path = path;
  static final LocalFeedStore instance = LocalFeedStore();

  // v2 adds linkJson (rich link previews) to sermons and feed_texts.
  static const int _dbVersion = 2;

  final DatabaseFactory? _factory;
  final String? _path;
  Future<Database>? _opening;

  bool get _inMemory => kIsWeb && _factory == null;

  final _sermonsController =
      StreamController<List<SermonAudio>>.broadcast();
  final _textsController = StreamController<List<TextMessage>>.broadcast();
  final _reactionsController =
      StreamController<Map<String, Map<String, int>>>.broadcast();

  // In-memory fallback, used only when kIsWeb.
  final Map<String, SermonAudio> _memSermons = {};
  final Map<String, TextMessage> _memTexts = {};
  final Map<String, Map<String, int>> _memReactions = {};

  Future<Database> get _database => _opening ??= _open();

  Future<Database> _open() async {
    final factory = _factory ?? databaseFactory;
    final path =
        _path ?? join(await factory.getDatabasesPath(), 'local_feed_store.db');
    return factory.openDatabase(path,
        options: OpenDatabaseOptions(
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sermons (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            audioUrl TEXT NOT NULL DEFAULT '',
            mediaType TEXT NOT NULL DEFAULT 'AUDIO',
            senderId TEXT NOT NULL DEFAULT '',
            senderName TEXT NOT NULL DEFAULT '',
            timestamp INTEGER NOT NULL DEFAULT 0,
            linkJson TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_sermons_ts ON sermons(timestamp)');

        await db.execute('''
          CREATE TABLE feed_texts (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL DEFAULT '',
            timestamp INTEGER NOT NULL DEFAULT 0,
            replyToId TEXT NOT NULL DEFAULT '',
            replyToType TEXT NOT NULL DEFAULT '',
            replyToPreview TEXT NOT NULL DEFAULT '',
            senderId TEXT NOT NULL DEFAULT '',
            senderName TEXT NOT NULL DEFAULT '',
            senderPhone TEXT NOT NULL DEFAULT '',
            linkJson TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_feed_texts_ts ON feed_texts(timestamp)');

        await db.execute('''
          CREATE TABLE feed_reactions (
            itemId TEXT NOT NULL,
            emoji TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (itemId, emoji)
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Additive only — every cached post is kept.
          await db.execute(
              "ALTER TABLE sermons ADD COLUMN linkJson TEXT NOT NULL DEFAULT ''");
          await db.execute(
              "ALTER TABLE feed_texts ADD COLUMN linkJson TEXT NOT NULL DEFAULT ''");
        }
      },
    ));
  }

  /// Newest timestamp stored across sermons and text posts (0 when empty):
  /// the network only needs to bring what came after it.
  Future<int> latestTimestamp() async {
    if (_inMemory) {
      final all = [
        ..._memSermons.values.map((s) => s.timestamp),
        ..._memTexts.values.map((t) => t.timestamp),
      ];
      return all.isEmpty ? 0 : all.reduce((a, b) => a > b ? a : b);
    }
    final db = await _database;
    final r = await db.rawQuery('SELECT MAX(t) AS m FROM ('
        'SELECT MAX(timestamp) AS t FROM sermons UNION ALL '
        'SELECT MAX(timestamp) AS t FROM feed_texts)');
    return (r.first['m'] as num?)?.toInt() ?? 0;
  }

  /// Every stored post, oldest first — one read for the first frame.
  Future<({List<SermonAudio> sermons, List<TextMessage> texts})> loadAll() async =>
      (sermons: await _fetchSermons(), texts: await _fetchTexts());

  Future<({List<SermonAudio> sermons, List<TextMessage> texts})>? _preload;

  /// The first [loadAll] of this launch, shared: main() starts it before
  /// anything else, so the feed is usually read by the time it's drawn.
  Future<({List<SermonAudio> sermons, List<TextMessage> texts})> preload() =>
      _preload ??= loadAll();

  @visibleForTesting
  Future<void> close() async {
    final db = await _opening;
    await db?.close();
    _opening = null;
  }

  // ---------------------------------------------------------------------
  // Sermons / media items
  // ---------------------------------------------------------------------

  Future<void> upsertSermon(SermonAudio sermon) => upsertSermons([sermon]);

  /// Batch upsert — one DB round trip and one stream emission for the whole
  /// snapshot, instead of per-row (a `limitToLast` `.onValue` re-delivers
  /// every child on any change).
  Future<void> upsertSermons(List<SermonAudio> sermons) async {
    if (sermons.isEmpty) return;
    if (_inMemory) {
      for (final s in sermons) {
        _memSermons[s.id] = s;
      }
      await _refreshSermons();
      return;
    }
    final db = await _database;
    final batch = db.batch();
    for (final s in sermons) {
      batch.insert('sermons', s.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await _refreshSermons();
  }

  Future<void> deleteSermon(String id) async {
    if (_inMemory) {
      _memSermons.remove(id);
      await _refreshSermons();
      return;
    }
    final db = await _database;
    await db.delete('sermons', where: 'id = ?', whereArgs: [id]);
    await _refreshSermons();
  }

  Future<List<SermonAudio>> _fetchSermons() async {
    if (_inMemory) {
      final list = _memSermons.values.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return list;
    }
    final db = await _database;
    final rows = await db.query('sermons', orderBy: 'timestamp ASC');
    return rows.map(SermonAudio.fromDbMap).toList();
  }

  Future<void> _refreshSermons() async {
    if (_sermonsController.isClosed) return;
    _sermonsController.add(await _fetchSermons());
  }

  Stream<List<SermonAudio>> observeSermons() {
    _fetchSermons().then((rows) {
      if (!_sermonsController.isClosed) _sermonsController.add(rows);
    });
    return _sermonsController.stream;
  }

  // ---------------------------------------------------------------------
  // Feed text-posts
  // ---------------------------------------------------------------------

  Future<void> upsertText(TextMessage message) => upsertTexts([message]);

  Future<void> upsertTexts(List<TextMessage> messages) async {
    if (messages.isEmpty) return;
    if (_inMemory) {
      for (final m in messages) {
        _memTexts[m.id] = m;
      }
      await _refreshTexts();
      return;
    }
    final db = await _database;
    final batch = db.batch();
    for (final m in messages) {
      batch.insert('feed_texts', m.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await _refreshTexts();
  }

  Future<void> deleteText(String id) async {
    if (_inMemory) {
      _memTexts.remove(id);
      await _refreshTexts();
      return;
    }
    final db = await _database;
    await db.delete('feed_texts', where: 'id = ?', whereArgs: [id]);
    await _refreshTexts();
  }

  Future<List<TextMessage>> _fetchTexts() async {
    if (_inMemory) {
      final list = _memTexts.values.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return list;
    }
    final db = await _database;
    final rows = await db.query('feed_texts', orderBy: 'timestamp ASC');
    return rows.map(TextMessage.fromDbMap).toList();
  }

  Future<void> _refreshTexts() async {
    if (_textsController.isClosed) return;
    _textsController.add(await _fetchTexts());
  }

  Stream<List<TextMessage>> observeTexts() {
    _fetchTexts().then((rows) {
      if (!_textsController.isClosed) _textsController.add(rows);
    });
    return _textsController.stream;
  }

  // ---------------------------------------------------------------------
  // Reactions (whole map replaced on each Firebase snapshot)
  // ---------------------------------------------------------------------

  Future<void> replaceReactions(Map<String, Map<String, int>> reactions) async {
    if (_inMemory) {
      _memReactions
        ..clear()
        ..addAll(reactions.map((k, v) => MapEntry(k, Map<String, int>.from(v))));
      await _refreshReactions();
      return;
    }
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('feed_reactions');
      for (final entry in reactions.entries) {
        for (final emoji in entry.value.entries) {
          await txn.insert('feed_reactions', {
            'itemId': entry.key,
            'emoji': emoji.key,
            'count': emoji.value,
          });
        }
      }
    });
    await _refreshReactions();
  }

  /// One item's reaction counts changed (or [counts] is empty: removed).
  Future<void> setItemReactions(String itemId, Map<String, int> counts) async {
    if (_inMemory) {
      if (counts.isEmpty) {
        _memReactions.remove(itemId);
      } else {
        _memReactions[itemId] = Map<String, int>.from(counts);
      }
      await _refreshReactions();
      return;
    }
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('feed_reactions', where: 'itemId = ?', whereArgs: [itemId]);
      for (final e in counts.entries) {
        await txn.insert('feed_reactions',
            {'itemId': itemId, 'emoji': e.key, 'count': e.value});
      }
    });
    await _refreshReactions();
  }

  Future<Map<String, Map<String, int>>> _fetchReactions() async {
    if (_inMemory) {
      return _memReactions
          .map((k, v) => MapEntry(k, Map<String, int>.from(v)));
    }
    final db = await _database;
    final rows = await db.query('feed_reactions');
    final out = <String, Map<String, int>>{};
    for (final r in rows) {
      final itemId = r['itemId'] as String;
      out.putIfAbsent(itemId, () => {})[r['emoji'] as String] =
          (r['count'] as num?)?.toInt() ?? 0;
    }
    return out;
  }

  Future<void> _refreshReactions() async {
    if (_reactionsController.isClosed) return;
    _reactionsController.add(await _fetchReactions());
  }

  Stream<Map<String, Map<String, int>>> observeReactions() {
    _fetchReactions().then((map) {
      if (!_reactionsController.isClosed) _reactionsController.add(map);
    });
    return _reactionsController.stream;
  }
}
