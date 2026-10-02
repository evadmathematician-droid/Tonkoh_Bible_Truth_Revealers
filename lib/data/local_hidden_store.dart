import 'package:shared_preferences/shared_preferences.dart';

/// Per-device "delete for me" list for the audio discussion feed.
///
/// Feed items (sermons / text posts) live in Firebase and are shared by
/// everyone, so a user deleting one must only hide it on their own
/// device — never remove it for others. Hidden ids are persisted here and
/// filtered out of the feed on load.
class LocalHiddenStore {
  LocalHiddenStore._();
  static final LocalHiddenStore instance = LocalHiddenStore._();

  static const _key = 'audio_feed_hidden_ids';
  Set<String> _ids = {};
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _ids = (prefs.getStringList(_key) ?? const []).toSet();
    _loaded = true;
  }

  Future<Set<String>> hiddenIds() async {
    await _ensureLoaded();
    return _ids;
  }

  bool isHidden(String id) => _ids.contains(id);

  Future<void> hide(String id) async {
    await _ensureLoaded();
    if (_ids.add(id)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, _ids.toList());
    }
  }
}
