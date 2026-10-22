import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../chat_media/chat_media_sender.dart';
import '../screens/auth/auth_manager.dart';
import '../screens/chat/chat_helpers.dart' show previewLabelFor;
import '../screens/chat/private_chat_push.dart';
import 'chat_summary.dart';
import 'local_chat_store.dart';
import 'private_message.dart';
import 'profile_photo_cache.dart';

/// Keeps the phone's copy of every conversation current in the background,
/// WhatsApp-style, so opening a chat never waits for the network:
///
///  * mirrors `userChats/{me}` into the local chat list (Discussions);
///  * listens to the relay (`privateChats/{chatId}/messages`) of every chat
///    and saves incoming messages to [LocalChatStore] as they arrive —
///    before the chat is even opened — then removes them from the relay,
///    exactly as the chat screen used to do while open;
///  * marks my messages *delivered* when the other phone removes them;
///  * sends my messages: saved locally first (pending), uploaded after,
///    retried from the outbox when the connection comes back or the app
///    restarts.
class ChatSyncService {
  ChatSyncService._();
  static final ChatSyncService instance = ChatSyncService._();

  final FirebaseDatabase _db = FirebaseDatabase.instance;

  String? _me;
  StreamSubscription<DatabaseEvent>? _chatsSub;
  StreamSubscription<DatabaseEvent>? _connectedSub;
  final Map<String, List<StreamSubscription<DatabaseEvent>>> _relaySubs = {};

  // Incoming relay messages are saved in small batches per chat.
  final Map<String, List<(PrivateMessage, DatabaseReference)>> _buffer = {};
  final Map<String, Timer> _flushTimers = {};

  final Set<String> _sending = {};
  final Map<String, String> _profileNames = {};

  String? get currentUid => _me;

  /// Start for the signed-in account [myUid]. Restarts if the id changed
  /// (account repair / re-registration).
  Future<void> start(String myUid) async {
    if (_me == myUid) return;
    await stop();
    _me = myUid;

    // Photo/video uploads the last app session didn't finish → "Tap to
    // retry" (they can't still be running).
    await ChatMediaSender.instance.recoverAfterRestart();

    // Keep the chat list current in Firebase's disk cache even between
    // listeners, so it is already fresh when the app comes back.
    if (!kIsWeb) {
      try {
        await _db.ref('userChats/$myUid').keepSynced(true);
      } catch (e) {
        debugPrint('ChatSync: keepSynced unavailable: $e');
      }
    }

    _chatsSub = _db.ref('userChats/$myUid').onValue.listen((event) {
      final data = event.snapshot.value;
      final list = <ChatSummary>[];
      if (data is Map) {
        data.forEach((key, value) {
          if (value is Map) list.add(ChatSummary.fromMap(key.toString(), value));
        });
      }
      unawaited(LocalChatStore.instance.replaceChats(list));
      for (final c in list) {
        watchChat(c.chatId);
      }
    }, onError: (Object e) => debugPrint('ChatSync: chat list: $e'));

    // Back online → send whatever is still pending.
    _connectedSub = _db.ref('.info/connected').onValue.listen((event) {
      if (event.snapshot.value == true) unawaited(flushOutbox());
    });
    unawaited(flushOutbox());
  }

  Future<void> stop() async {
    await _chatsSub?.cancel();
    await _connectedSub?.cancel();
    for (final subs in _relaySubs.values) {
      for (final s in subs) {
        await s.cancel();
      }
    }
    _relaySubs.clear();
    for (final t in _flushTimers.values) {
      t.cancel();
    }
    _flushTimers.clear();
    _buffer.clear();
    _me = null;
  }

  /// Make sure [chatId]'s relay is being listened to (the chat screen calls
  /// this too, for a chat that isn't in the list yet).
  void watchChat(String chatId) {
    if (_me == null || _relaySubs.containsKey(chatId)) return;
    final ref = _db.ref('privateChats/$chatId/messages');
    _relaySubs[chatId] = [
      ref.onChildAdded.listen((e) => _onRelayAdded(chatId, e.snapshot),
          onError: (Object e) => debugPrint('ChatSync: relay $chatId: $e')),
      ref.onChildRemoved.listen((e) => _onRelayRemoved(chatId, e.snapshot),
          onError: (_) {}),
    ];
  }

  void _onRelayAdded(String chatId, DataSnapshot snap) {
    final key = snap.key;
    final val = snap.value;
    if (key == null || val is! Map) return;
    final msg = PrivateMessage.fromFirebaseMap(key, val);
    (_buffer[chatId] ??= []).add((msg, snap.ref));
    _flushTimers[chatId] ??=
        Timer(const Duration(milliseconds: 60), () => _flush(chatId));
  }

  Future<void> _flush(String chatId) async {
    _flushTimers.remove(chatId);
    final items = _buffer.remove(chatId) ?? const [];
    if (items.isEmpty) return;
    final me = _me;
    try {
      await LocalChatStore.instance
          .insertIncoming(chatId, [for (final (m, _) in items) m]);
    } catch (e) {
      debugPrint('ChatSync: local save failed for $chatId: $e');
      return; // keep them on the relay; the next listen retries
    }
    // Saved on this phone → take the other person's messages off the relay
    // (my own stay until the other phone picks them up).
    for (final (m, ref) in items) {
      if (me == null) continue;
      if (m.senderId != me) {
        unawaited(ref.remove());
      } else {
        // On the relay means on the server, even if this phone missed the
        // write acknowledgement (app closed while sending).
        unawaited(LocalChatStore.instance
            .setStatus(chatId, m.id, MessageStatus.sent));
      }
    }
  }

  void _onRelayRemoved(String chatId, DataSnapshot snap) {
    final val = snap.value;
    if (val is! Map || snap.key == null) return;
    if (val['senderId'] == _me) {
      unawaited(LocalChatStore.instance
          .setStatus(chatId, snap.key!, MessageStatus.delivered));
    }
  }

  /// Uploads [message] (already saved locally as pending), then updates both
  /// chat summaries and notifies the other person. Safe to call again for
  /// the same message — it is written under its own id.
  Future<void> send({
    required String chatId,
    required String otherUid,
    required PrivateMessage message,
    String? preview,
  }) async {
    if (!_sending.add(message.id)) return;
    try {
      await _db
          .ref('privateChats/$chatId/messages/${message.id}')
          .set(message.toFirebaseMap());
      await LocalChatStore.instance
          .setStatus(chatId, message.id, MessageStatus.sent);
      watchChat(chatId);
      final label = preview ?? previewLabelFor(message);
      unawaited(_writeSummaries(chatId, otherUid, label, message.timestamp));
      unawaited(sendPrivateChatPushNotification(
        otherUid: otherUid,
        chatId: chatId,
        senderName: message.senderName,
        messageBody: label,
        senderUid: message.senderId,
      ));
    } catch (e) {
      debugPrint('ChatSync: send ${message.id} failed, stays pending: $e');
    } finally {
      _sending.remove(message.id);
    }
  }

  /// Sends every message still pending on this phone.
  Future<void> flushOutbox() async {
    final me = _me;
    if (me == null) return;
    try {
      final pending = await LocalChatStore.instance.pendingOutgoing(me);
      for (final p in pending) {
        final parts = p.chatId.split('_');
        if (parts.length != 2) continue;
        final other = parts[0] == me ? parts[1] : parts[0];
        // Not awaited: offline, each send waits for the connection.
        unawaited(send(chatId: p.chatId, otherUid: other, message: p.message));
      }
    } catch (e) {
      debugPrint('ChatSync: outbox failed: $e');
    }
  }

  Future<String> _nameOf(String uid) async {
    final known = _profileNames[uid];
    if (known != null) return known;
    try {
      final snap = await _db.ref('users/$uid/name').get();
      final name = (snap.value as String?)?.trim() ?? '';
      return _profileNames[uid] = name;
    } catch (_) {
      return '';
    }
  }

  Future<void> _writeSummaries(
      String chatId, String otherUid, String lastMessage, int timestamp) async {
    final me = await AuthManager.getCachedProfile();
    if (me == null) return;
    try {
      final otherName = await _nameOf(otherUid);
      await _db.ref('userChats/${me.uid}/$chatId').set(ChatSummary(
            chatId: chatId,
            otherUid: otherUid,
            otherName: otherName.isEmpty ? 'Chat' : otherName,
            otherPhotoUrl: ProfilePhotoCache.instance.photoFor(otherUid) ?? '',
            lastMessage: lastMessage,
            lastTimestamp: timestamp,
            unread: 0,
            lastReadTimestamp: timestamp,
          ).toFirebaseMap());

      final recipientRef = _db.ref('userChats/$otherUid/$chatId');
      await recipientRef.update({
        'otherUid': me.uid,
        'otherName': me.name.isEmpty ? me.phone : me.name,
        'otherPhotoUrl': me.photoUrl,
        'lastMessage': lastMessage,
        'lastTimestamp': timestamp,
      });
      await recipientRef.child('unread').runTransaction((current) {
        final n = (current as num?)?.toInt() ?? 0;
        return Transaction.success(n + 1);
      });
    } catch (e) {
      debugPrint('ChatSync: summaries for $chatId failed: $e');
    }
  }
}
