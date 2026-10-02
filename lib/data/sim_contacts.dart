import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads contacts stored on the SIM card(s) via the native
/// `com.tbtrapp/sim_contacts` channel (`SimContactsReader.kt`).
///
/// `flutter_contacts` only sees `ContactsContract` rows. Numbers saved
/// directly on a SIM (very common on Africell / Orange SIMs that people move
/// between phones) live in the separate `content://icc/adn` provider and, on
/// a dual-SIM phone, in a per-SIM table — none of which `ContactsContract`
/// exposes unless the user has explicitly imported them. This surfaces them
/// so [ContactsRepository] can merge them into the same device-contact list.
///
/// Android only; returns `[]` everywhere else and on any channel error.
class SimContacts {
  static const MethodChannel _channel = MethodChannel('com.tbtrapp/sim_contacts');

  static Future<List<({String name, String number})>> getAll() async {
    if (kIsWeb || !Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'getSimContacts',
      );
      if (raw == null) return const [];
      final out = <({String name, String number})>[];
      for (final row in raw) {
        final number = (row['number'] as String?)?.trim() ?? '';
        if (number.isEmpty) continue;
        final name = (row['name'] as String?)?.trim() ?? '';
        out.add((name: name, number: number));
      }
      debugPrint('[ContactsDebug] SIM contacts -> ${out.length}');
      return out;
    } catch (e) {
      debugPrint('[ContactsDebug] SIM contact read failed: $e');
      return const [];
    }
  }
}
