import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../screens/auth/auth_manager.dart';
import '../screens/chat/chat_helpers.dart' show privateChatId;
import '../util/phone_utils.dart';
import 'local_chat_store.dart';
import 'phone_aliases.dart';

/// Fixes this device's own account id when it was saved in a malformed
/// format by an older app version (`+031932652`, `+44034909376`), so users
/// who just install the update are repaired without re-registering.
///
///  * If tools/fix_phone_numbers.js already moved the account on the
///    server, only the local side changes: the cached profile and the
///    local chat history are re-keyed to the correct E.164 id.
///  * If not, the account record is moved here — copy → verify → delete —
///    together with this user's own chat list, and `phoneAliases/{old}` is
///    written so other users' old data still finds them.
///
/// Every server step is best-effort; nothing local changes unless the
/// account exists under the correct key afterwards.
class AccountSelfRepair {
  AccountSelfRepair._();

  static bool _running = false;

  /// Returns the corrected account id if this device was re-pointed to it,
  /// otherwise null (already correct, or the repair couldn't finish).
  static Future<String?> run() async {
    if (_running) return null;
    _running = true;
    try {
      return await _run();
    } catch (e) {
      debugPrint('AccountSelfRepair: failed: $e');
      return null;
    } finally {
      _running = false;
    }
  }

  static Future<String?> _run() async {
    final cached = await AuthManager.getCachedProfile();
    if (cached == null) return null;
    final old = cached.uid;
    if (!looksLikePhone(old)) return null; // very old non-phone account
    final target = resolveUserId(old);
    if (target == old || !isE164(target)) return null;

    final db = FirebaseDatabase.instance;
    final targetSnap = await db.ref('users/$target').get();
    if (!targetSnap.exists) {
      final oldSnap = await db.ref('users/$old').get();
      if (oldSnap.value is! Map) return null;

      final data = Map<String, dynamic>.from(oldSnap.value as Map)
        ..['uid'] = target
        ..['phone'] = target
        ..['country'] = countryOfPhone(target) ?? cached.country;
      await db.ref('users/$target').set(data);
      final check = await db.ref('users/$target/uid').get();
      if (check.value != target) return null;

      await _moveOwnChatList(db, old, target);
      try {
        await db.ref('phoneAliases/$old').set(target);
      } catch (e) {
        debugPrint('AccountSelfRepair: alias write failed: $e');
      }
      try {
        await db.ref('users/$old').remove();
      } catch (e) {
        debugPrint('AccountSelfRepair: old record not removed: $e');
      }
    }

    await AuthManager.adoptRepairedAccountId(target);
    await LocalChatStore.instance.renameUser(old, target);
    debugPrint('AccountSelfRepair: $old → $target');
    return target;
  }

  static Future<void> _moveOwnChatList(
      FirebaseDatabase db, String old, String target) async {
    try {
      final snap = await db.ref('userChats/$old').get();
      final value = snap.value;
      if (value is! Map) return;
      final updates = <String, Object?>{};
      value.forEach((cid, summary) {
        if (summary is! Map) return;
        final other = resolveUserId((summary['otherUid'] ?? '').toString());
        final newCid = other.isEmpty
            ? cid.toString().replaceAll(old, target)
            : privateChatId(target, other);
        updates['userChats/$target/$newCid'] = {
          ...Map<String, dynamic>.from(summary),
          if (other.isNotEmpty) 'otherUid': other,
        };
      });
      if (updates.isNotEmpty) await db.ref().update(updates);
      await db.ref('userChats/$old').remove();
    } catch (e) {
      debugPrint('AccountSelfRepair: chat list not moved: $e');
    }
  }
}
