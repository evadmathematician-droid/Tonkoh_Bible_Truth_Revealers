import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Decodes base64 image strings once and hands back the same [Uint8List]
/// for the same string on later calls.
///
/// Flutter's image cache keys `MemoryImage` / `Image.memory` by the identity
/// of the byte list. Calling `base64Decode` inside `build()` produces a new
/// list on every rebuild, so each rebuild missed the cache, decoded the
/// bitmap again and stored another copy of it. Reusing the list makes those
/// rebuilds cache hits.
///
/// Least-recently-used entries are dropped once the held bytes pass
/// [_maxBytes].
class Base64ImageCache {
  Base64ImageCache._();

  static const int _maxBytes = 8 * 1024 * 1024;

  static final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();
  static int _heldBytes = 0;

  /// Returns the decoded bytes, or null if [base64] is null, empty or not
  /// valid base64.
  static Uint8List? decode(String? base64) {
    if (base64 == null || base64.isEmpty) return null;

    final hit = _entries.remove(base64);
    if (hit != null) {
      _entries[base64] = hit; // move to most-recently-used
      return hit;
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(base64);
    } catch (_) {
      return null;
    }

    _entries[base64] = bytes;
    _heldBytes += bytes.length;
    while (_heldBytes > _maxBytes && _entries.length > 1) {
      final oldest = _entries.keys.first;
      _heldBytes -= _entries.remove(oldest)!.length;
    }
    return bytes;
  }
}
