import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/util/base64_image_cache.dart';

void main() {
  test('returns the same byte list for the same string', () {
    final encoded = base64Encode(List<int>.generate(64, (i) => i));
    final first = Base64ImageCache.decode(encoded);
    final second = Base64ImageCache.decode(encoded);
    expect(first, isNotNull);
    // Identity, not just equality — Flutter's image cache keys on it.
    expect(identical(first, second), isTrue);
    expect(first, List<int>.generate(64, (i) => i));
  });

  test('returns null for empty, null or invalid input', () {
    expect(Base64ImageCache.decode(null), isNull);
    expect(Base64ImageCache.decode(''), isNull);
    expect(Base64ImageCache.decode('not base64!'), isNull);
  });

  test('evicts old entries once past the size cap', () {
    final oneMb = List<int>.filled(1024 * 1024, 7);
    final firstKey = base64Encode([...oneMb, 0]);
    final first = Base64ImageCache.decode(firstKey);
    for (var i = 1; i <= 9; i++) {
      Base64ImageCache.decode(base64Encode([...oneMb, i]));
    }
    // 10 MB were added against an 8 MB cap, so the oldest entry is gone and
    // decoding it again yields a fresh list.
    expect(identical(Base64ImageCache.decode(firstKey), first), isFalse);
  });
}
