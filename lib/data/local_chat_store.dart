import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/private_message.dart';

/// Dart equivalent of the Kotlin `AppDatabase` / `MessageDao` (Room).
/// This — not Firebase — is the source of truth for message history,
/// same as the Kotlin version. Firebase is only a delivery relay
/// (see private_chat_screen.dart).
///
/// sqflite has no web implementation, so on web this is backed by
/// shared_preferences instead (whose web implementation is backed by
/// localStorage, so it survives page refreshes — a bare in-memory map
/// here previously meant every message got permanently lost the moment
/// a web user refreshed, since _listenRelay() in private_chat_screen.dart
/// already deletes each message from Firebase right after handing it to
/// this store). Every other platform uses real SQLite via sqflite.
class LocalChatStore {
  LocalChatStore._();
  static final LocalChatStore instance = LocalChatStore._();

  // v2 added `waveform`. v3 adds `listened` (read/unread tracking for
  // voice + regular messages).
  static const int _dbVersion = 3;

  Database? _db;
  final Map<String, StreamController<List<PrivateMessage>>> _controllers = {};

  // Web-only: in-memory cache backed by shared_preferences (see class doc).
  final Map<String, List<PrivateMessage>> _memStore = {};
  final Set<String> _webHydratedChats = {};

  static String _webPrefsKey(String chatId) => 'local_chat_store_web_$chatId';

  /// Loads this chat's messages from shared_preferences into _memStore the
  /// first time it's touched in this session. A no-op on every call after
  /// the first for a given chatId, and on non-web platforms.
  Future<void> _ensureWebHydrated(String chatId) async {
    if (!kIsWeb || _webHydratedChats.contains(chatId)) return;
    _webHydratedChats.add(chatId);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_webPrefsKey(chatId));
    if (raw == null) return;

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final messages = decoded
          .map((e) => PrivateMessage.fromDbMap(Map<String, Object?>.from(e as Map)))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _memStore[chatId] = messages;
    } catch (_) {
      // Corrupt/unreadable saved data — start this chat fresh rather than
      // crash it permanently.
    }
  }

  Future<void> _persistWeb(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _memStore[chatId] ?? const <PrivateMessage>[];
    final encoded = jsonEncode(list.map((m) => m.toDbMap(chatId)).toList());
    await prefs.setString(_webPrefsKey(chatId), encoded);
  }

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'local_chat_store.db');
    _db = await openDatabase(
      path,
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
            PRIMARY KEY (id, chatId)
          )
        ''');
        await db.execute('CREATE INDEX idx_messages_chatId ON messages(chatId)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Existing installs: add the waveform column without
          // touching any already-saved messages/media.
          await db.execute(
            "ALTER TABLE messages ADD COLUMN waveform TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 3) {
          // Everything saved before this migration is, by definition,
          // stuff the user has already seen in the old UI — default
          // it to listened=1 so old history doesn't suddenly show as
          // unread. Only newly-inserted messages after this point
          // start at 0.
          await db.execute(
            'ALTER TABLE messages ADD COLUMN listened INTEGER NOT NULL DEFAULT 1',
          );
        }
      },
    );
    return _db!;
  }

  /// Insert (or replace) a message and push the refreshed list to any
  /// active observer for that chat. Equivalent to db.messageDao().insert().
  Future<void> insert(String chatId, PrivateMessage message) async {
    if (kIsWeb) {
      await _ensureWebHydrated(chatId);
      final list = _memStore.putIfAbsent(chatId, () => []);
      list.removeWhere((m) => m.id == message.id);
      list.add(message);
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      await _persistWeb(chatId);
      await _refresh(chatId);
      return;
    }

    final db = await _database;
    await db.insert(
      'messages',
      message.toDbMap(chatId),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _refresh(chatId);
  }

  /// Marks a single message as listened/read and pushes the updated
  /// list to any active observer. Call this the moment playback starts
  /// for a voice message (or immediately on render for text, depending
  /// on what "read" means in your app).
  Future<void> markListened(String chatId, String messageId) async {
    if (kIsWeb) {
      await _ensureWebHydrated(chatId);
      final list = _memStore[chatId];
      if (list == null) return;
      final idx = list.indexWhere((m) => m.id == messageId);
      if (idx == -1 || list[idx].listened) return;
      list[idx] = list[idx].copyWith(listened: true);
      await _persistWeb(chatId);
      await _refresh(chatId);
      return;
    }

    final db = await _database;
    final updated = await db.update(
      'messages',
      {'listened': 1},
      where: 'id = ? AND chatId = ? AND listened = 0',
      whereArgs: [messageId, chatId],
    );
    if (updated > 0) {
      await _refresh(chatId);
    }
  }

  /// Marks every message in a chat as listened — handy for "mark all
  /// as read" on chat open, if you want that instead of/alongside
  /// per-message tracking.
  Future<void> markAllListened(String chatId) async {
    if (kIsWeb) {
      await _ensureWebHydrated(chatId);
      final list = _memStore[chatId];
      if (list == null) return;
      var changed = false;
      for (var i = 0; i < list.length; i++) {
        if (!list[i].listened) {
          list[i] = list[i].copyWith(listened: true);
          changed = true;
        }
      }
      if (changed) {
        await _persistWeb(chatId);
        await _refresh(chatId);
      }
      return;
    }

    final db = await _database;
    final updated = await db.update(
      'messages',
      {'listened': 1},
      where: 'chatId = ? AND listened = 0',
      whereArgs: [chatId],
    );
    if (updated > 0) {
      await _refresh(chatId);
    }
  }

  Future<List<PrivateMessage>> _fetch(String chatId) async {
    if (kIsWeb) {
      await _ensureWebHydrated(chatId);
      return List<PrivateMessage>.from(_memStore[chatId] ?? const []);
    }

    final db = await _database;
    final rows = await db.query(
      'messages',
      where: 'chatId = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );
    return rows.map((r) => PrivateMessage.fromDbMap(r)).toList();
  }

  Future<void> _refresh(String chatId) async {
    final controller = _controllers[chatId];
    if (controller == null || controller.isClosed) return;
    controller.add(await _fetch(chatId));
  }

  /// Equivalent to db.messageDao().observeMessages(chatId) — a live
  /// stream of the full message list for a chat, backed by SQLite
  /// (or shared_preferences/localStorage on web).
  Stream<List<PrivateMessage>> observeMessages(String chatId) {
    var controller = _controllers[chatId];
    if (controller == null || controller.isClosed) {
      controller = StreamController<List<PrivateMessage>>.broadcast(
        onCancel: () => _controllers.remove(chatId),
      );
      _controllers[chatId] = controller;
      // Emit current contents immediately on subscribe.
      _fetch(chatId).then((msgs) {
        if (!controller!.isClosed) controller.add(msgs);
      });
    }
    return controller.stream;
  }
}