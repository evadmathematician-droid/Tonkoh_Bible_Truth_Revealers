import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'app_contact.dart';

/// Local persistence layer backing the Contacts screen — the Dart/sqflite
/// equivalent of a Room table. This is the source of truth the Contacts
/// screen reads from; it is populated by a background sync
/// (ContactsSyncService), never by querying flutter_contacts/Firebase
/// directly from the screen on every render. Same file-layout convention
/// as LocalChatStore (its sqflite/web-shared_preferences split, its
/// onCreate/onUpgrade shape).
///
/// Two logical kinds of row share one table, distinguished by [source]:
///  - 'DEVICE': a device contact whose number matched a registered user.
///  - 'CHAT_ONLY': a registered user the current user has an active chat
///    with, but who is NOT in device contacts — shown by phone number,
///    same as an unsaved WhatsApp/Telegram chat.
/// On a phone-number collision between the two (you're chatting with
/// someone who's also in your device contacts), the DEVICE row wins,
/// since ContactsSyncService always upserts CHAT_ONLY rows first, then
/// DEVICE rows, with ConflictAlgorithm.replace on the `phone` primary key.
class LocalContactStore {
  LocalContactStore._();
  static final LocalContactStore instance = LocalContactStore._();

  static const int _dbVersion = 1;

  Database? _db;
  final StreamController<List<AppContact>> _controller =
      StreamController<List<AppContact>>.broadcast();

  // Web-only: sqflite has no web implementation (see LocalChatStore's note
  // on the same gap) — backed by shared_preferences/localStorage instead.
  List<AppContact> _memStore = [];
  bool _webHydrated = false;

  static const _webPrefsKey = 'local_contact_store_web';

  Future<void> _ensureWebHydrated() async {
    if (!kIsWeb || _webHydrated) return;
    _webHydrated = true;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_webPrefsKey);
    if (raw == null) return;

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _memStore = decoded
          .map((e) => _contactFromMap(Map<String, Object?>.from(e as Map)))
          .toList();
    } catch (_) {
      // Corrupt/unreadable saved data — start fresh rather than crash.
    }
  }

  Future<void> _persistWeb() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_memStore.map(_contactToMap).toList());
    await prefs.setString(_webPrefsKey, encoded);
  }

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'local_contact_store.db');
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            phone TEXT PRIMARY KEY,
            uid TEXT,
            name TEXT NOT NULL,
            photoUrl TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL,
            lastSyncedAt INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_contacts_source ON contacts(source)');
      },
    );
    return _db!;
  }

  Map<String, Object?> _contactToMap(AppContact c) => {
        'phone': c.phone,
        'uid': c.uid,
        'name': c.name,
        'photoUrl': c.photoUrl ?? '',
        'source': c.source,
        'lastSyncedAt': DateTime.now().millisecondsSinceEpoch,
      };

  AppContact _contactFromMap(Map<String, Object?> map) => AppContact(
        name: map['name'] as String? ?? '',
        phone: map['phone'] as String? ?? '',
        uid: map['uid'] as String?,
        photoUrl: (map['photoUrl'] as String?)?.isEmpty ?? true
            ? null
            : map['photoUrl'] as String,
        source: map['source'] as String? ?? 'UNKNOWN',
      );

  /// Upserts a batch of contacts, then deletes any existing row with the
  /// given [source] that was NOT part of this batch — i.e. a full resync
  /// for that source. Phone is the merge key: a DEVICE upsert overwrites
  /// a same-phone CHAT_ONLY row (see class doc), never the reverse, as
  /// long as callers upsert CHAT_ONLY before DEVICE within one sync pass.
  Future<void> replaceSource(String source, List<AppContact> contacts) async {
    if (kIsWeb) {
      await _ensureWebHydrated();
      final phones = contacts.map((c) => c.phone).toSet();
      _memStore.removeWhere((c) => c.source == source && !phones.contains(c.phone));
      for (final c in contacts) {
        _memStore.removeWhere((existing) => existing.phone == c.phone);
        _memStore.add(c);
      }
      await _persistWeb();
      _controller.add(List<AppContact>.from(_memStore));
      return;
    }

    final db = await _database;
    await db.transaction((txn) async {
      for (final c in contacts) {
        await txn.insert(
          'contacts',
          _contactToMap(c),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      final phones = contacts.map((c) => "'${c.phone.replaceAll("'", "''")}'").join(',');
      if (phones.isEmpty) {
        await txn.delete('contacts', where: 'source = ?', whereArgs: [source]);
      } else {
        await txn.delete(
          'contacts',
          where: 'source = ? AND phone NOT IN ($phones)',
          whereArgs: [source],
        );
      }
    });
    await _refresh();
  }

  Future<List<AppContact>> getAll() async {
    if (kIsWeb) {
      await _ensureWebHydrated();
      final sorted = List<AppContact>.from(_memStore)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return sorted;
    }

    final db = await _database;
    final rows = await db.query('contacts', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map((r) => _contactFromMap(r)).toList();
  }

  Future<void> clearAll() async {
    if (kIsWeb) {
      await _ensureWebHydrated();
      _memStore = [];
      await _persistWeb();
      _controller.add([]);
      return;
    }
    final db = await _database;
    await db.delete('contacts');
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_controller.hasListener) {
      _controller.add(await getAll());
    }
  }

  /// Live stream of the full contacts list, refreshed after every sync.
  Stream<List<AppContact>> watchAll() {
    getAll().then((c) {
      if (!_controller.isClosed) _controller.add(c);
    });
    return _controller.stream;
  }
}
