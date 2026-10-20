import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'link_preview.dart';

/// Previews already fetched on this phone, by URL, so pasting the same link
/// again — or showing an old message that only contains a link — is
/// instant and works offline. Keeps the most recent [maxEntries].
class LinkPreviewCache {
  LinkPreviewCache._();
  static final LinkPreviewCache instance = LinkPreviewCache._();

  static const String _prefsKey = 'link_preview_cache_v1';
  static const int maxEntries = 300;

  final Map<String, LinkPreview> _memory = {};
  Future<void>? _loading;
  Timer? _saveTimer;

  Future<void> _load() => _loading ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final raw = prefs.getString(_prefsKey);
          if (raw == null) return;
          final list = jsonDecode(raw) as List;
          for (final e in list) {
            final p = LinkPreview.fromMap(e);
            if (p != null) _memory.putIfAbsent(p.url, () => p);
          }
        } catch (e) {
          debugPrint('LinkPreviewCache: unreadable, starting fresh: $e');
        }
      }();

  /// The cached preview for [url] (already loaded only).
  LinkPreview? peek(String url) => _memory[url];

  Future<LinkPreview?> get(String url) async {
    await _load();
    return _memory[url];
  }

  Future<void> put(String url, LinkPreview preview) async {
    await _load();
    _memory.remove(url);
    _memory[url] = preview; // most recent last
    while (_memory.length > maxEntries) {
      _memory.remove(_memory.keys.first);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _save);
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode([for (final p in _memory.values) p.toMap()]));
    } catch (e) {
      debugPrint('LinkPreviewCache: save failed: $e');
    }
  }

  @visibleForTesting
  void debugClear() {
    _memory.clear();
    _loading = Future.value();
  }
}
