import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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
  LocalFeedStore._();
  static final LocalFeedStore instance = LocalFeedStore._();

  static const int _dbVersion = 1;

  Database? _db;

  final _sermonsController =
      StreamController<List<SermonAudio>>.broadcast();
  final _textsController = StreamController<List<TextMessage>>.broadcast();
  final _reactionsController =
      StreamController<Map<String, Map<String, int>>>.broadcast();

  // In-memory fallback, used only when kIsWeb.
  final Map<String, SermonAudio> _memSermons = {};
  final Map<String, TextMessage> _memTexts = {};
  final Map<String, Map<String, int>> _memReactions = {};

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'local_feed_store.db');
    _db = await openDatabase(
      path,
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
            timestamp INTEGER NOT NULL DEFAULT 0
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
            senderPhone TEXT NOT NULL DEFAULT ''
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
    );
    return _db!;
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
    if (kIsWeb) {
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
    if (kIsWeb) {
      _memSermons.remove(id);
      await _refreshSermons();
      return;
    }
    final db = await _database;
    await db.delete('sermons', where: 'id = ?', whereArgs: [id]);
    await _refreshSermons();
  }

  Future<List<SermonAudio>> _fetchSermons() async {
    if (kIsWeb) {
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
    if (kIsWeb) {
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
    if (kIsWeb) {
      _memTexts.remove(id);
      await _refreshTexts();
      return;
    }
    final db = await _database;
    await db.delete('feed_texts', where: 'id = ?', whereArgs: [id]);
    await _refreshTexts();
  }

  Future<List<TextMessage>> _fetchTexts() async {
    if (kIsWeb) {
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
    if (kIsWeb) {
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

  Future<Map<String, Map<String, int>>> _fetchReactions() async {
    if (kIsWeb) {
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
