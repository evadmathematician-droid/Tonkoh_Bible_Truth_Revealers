import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';
import '../auth/auth_manager.dart';
import '../../data/feed_item.dart';
import '../../data/sermon_audio.dart';
import '../../data/text_message.dart';

/// Equivalent of the Firebase-listener + unread-tracking portion of
/// AudioScreen.kt's @Composable body. UI-agnostic on purpose — AudioScreen
/// (step 6d) will just `watch` this via provider.
class AudioFeedProvider extends ChangeNotifier {
  // ---------- Auth state (mirrors currentUid/currentSenderName/Phone) ----------
  String? currentUid;
  String currentSenderName = '';
  String currentSenderPhone = '';

  // ---------- Feed data ----------
  final List<SermonAudio> _sermons = [];
  final List<TextMessage> _textMessages = [];
  final Map<String, Map<String, int>> reactionsMap = {};

  // Item ids the CURRENT user has deleted "for me" — see deleteItemForMe().
  // This is a shared community feed (every user reads the same
  // sermons/approved and textMessages nodes), so deleting a message must
  // never remove it from those shared nodes; it only needs to stop
  // appearing in this user's own feedItems.
  final Set<String> _deletedForMe = {};

  List<FeedItem> get feedItems => buildFeedItems(_sermons, _textMessages)
      .where((item) => !_deletedForMe.contains(item.id))
      .toList();

  // ---------- Unread (private chats) badge, mirrors `totalUnread` ----------
  int totalUnread = 0;

  // ---------- Read-receipt state for the audio feed itself ----------
  int _lastReadTimestamp = 0;
  int get lastReadTimestamp => _lastReadTimestamp;

  int get unreadCount =>
      feedItems.where((f) => f.timestamp > _lastReadTimestamp).length;

  StreamSubscription? _userChatsSub;
  StreamSubscription? _textMessagesSub;
  StreamSubscription? _reactionsSub;
  StreamSubscription? _sermonsSub;
  StreamSubscription? _deletedForMeSub;

  final _textMessagesRef = FirebaseDatabase.instance.ref('textMessages');
  final _reactionsRef = FirebaseDatabase.instance.ref('reactions');
  final _sermonsRef =
  FirebaseDatabase.instance.ref('sermons').child('approved');

  /// Call once when the screen mounts (equivalent of the two
  /// LaunchedEffect(Unit) blocks in AudioScreen.kt).
  Future<void> init() async {
    await _loadLastReadTimestamp();

    await AuthManager.ensureSignedIn(
      onReady: () async {
        final cached = await AuthManager.getCachedProfile();
        if (cached != null) {
          currentUid = cached.uid;
          currentSenderName = cached.name;
          currentSenderPhone = cached.phone;
          _watchUserChats(cached.uid);
          _watchDeletedForMe(cached.uid);
          notifyListeners();
        }
      },
      onError: (msg) => debugPrint('AudioFeedProvider: ensureSignedIn failed: $msg'),
    );

    _watchTextMessages();
    _watchReactions();
    _watchSermons();
  }

  Future<void> _loadLastReadTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    _lastReadTimestamp = prefs.getInt('audio_screen_last_read_timestamp') ?? 0;
  }

  /// Mirrors the DisposableEffect(currentUid) watching userChats/{uid} for
  /// totalUnread.
  void _watchUserChats(String uid) {
    _userChatsSub?.cancel();
    final ref = FirebaseDatabase.instance.ref('userChats').child(uid);
    _userChatsSub = ref.onValue.listen((event) {
      int sum = 0;
      final value = event.snapshot.value;
      if (value is Map) {
        for (final child in value.values) {
          if (child is Map && child['unread'] is int) {
            sum += child['unread'] as int;
          }
        }
      }
      totalUnread = sum;
      notifyListeners();
    });
  }

  /// Mirrors textMessagesRef.orderByChild("timestamp").limitToLast(50).
  void _watchTextMessages() {
    _textMessagesSub = _textMessagesRef
        .orderByChild('timestamp')
        .limitToLast(50)
        .onValue
        .listen((event) {
      final parsed = <TextMessage>[];
      final value = event.snapshot.value;
      if (value is Map) {
        value.forEach((key, child) {
          if (child is Map) {
            final msg = TextMessage.fromMap(key as String, child);
            if (msg.text.isNotEmpty) parsed.add(msg);
          }
        });
      }
      _textMessages
        ..clear()
        ..addAll(parsed);
      notifyListeners();
    }, onError: (e) => debugPrint('RTDB textMessages error: $e'));
  }

  void _watchReactions() {
    _reactionsSub = _reactionsRef.onValue.listen((event) {
      final newMap = <String, Map<String, int>>{};
      final value = event.snapshot.value;
      if (value is Map) {
        value.forEach((itemKey, emojiMap) {
          if (emojiMap is Map) {
            final inner = <String, int>{};
            emojiMap.forEach((emojiKey, count) {
              inner[emojiKey as String] = (count as num?)?.toInt() ?? 0;
            });
            newMap[itemKey as String] = inner;
          }
        });
      }
      reactionsMap
        ..clear()
        ..addAll(newMap);
      notifyListeners();
    }, onError: (e) => debugPrint('RTDB reactions error: $e'));
  }

  /// Mirrors dbRef.orderByChild("timestamp") on sermons/approved.
  void _watchSermons() {
    _sermonsSub = _sermonsRef.orderByChild('timestamp').onValue.listen((event) {
      final parsed = <SermonAudio>[];
      final value = event.snapshot.value;
      if (value is Map) {
        value.forEach((key, child) {
          if (child is Map) {
            final sermon = SermonAudio.fromMap(key as String, child);
            if (sermon.audioUrl.isNotEmpty) parsed.add(sermon);
          }
        });
      }
      _sermons
        ..clear()
        ..addAll(parsed);
      notifyListeners();
    }, onError: (e) => debugPrint('RTDB sermons error: $e'));
  }

  void addReaction(String itemId, String emoji) {
    _reactionsRef.child(itemId).child(emoji).set(ServerValue.increment(1));
  }

  /// Watches which item ids the current user has personally deleted, so
  /// they can be filtered out of feedItems without touching the shared
  /// sermons/textMessages nodes everyone else still reads from.
  void _watchDeletedForMe(String uid) {
    _deletedForMeSub?.cancel();
    final ref = FirebaseDatabase.instance.ref('feedDeletedForMe').child(uid);
    _deletedForMeSub = ref.onValue.listen((event) {
      _deletedForMe.clear();
      final value = event.snapshot.value;
      if (value is Map) {
        _deletedForMe.addAll(value.keys.map((k) => k as String));
      }
      notifyListeners();
    }, onError: (e) => debugPrint('RTDB feedDeletedForMe error: $e'));
  }

  /// Deletes a feed item for the current user only. The item stays fully
  /// intact in sermons/approved or textMessages for every other user —
  /// this just records the id under this user's own deleted-for-me list.
  Future<void> deleteItemForMe(String itemId) async {
    final uid = currentUid;
    if (uid == null) return;
    await FirebaseDatabase.instance
        .ref('feedDeletedForMe')
        .child(uid)
        .child(itemId)
        .set(true);
  }

  Future<void> sendTextMessage(
      String text, {
        String? replyToId,
        String? replyToType,
        String? replyToPreview,
      }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final newRef = _textMessagesRef.push();
    await newRef.set(
      TextMessage(
        id: newRef.key ?? '',
        text: trimmed,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        replyToId: replyToId ?? '',
        replyToType: replyToType ?? '',
        replyToPreview: replyToPreview ?? '',
        senderId: currentUid ?? '',
        senderName: currentSenderName,
        senderPhone: currentSenderPhone,
      ).toMap(),
    );
    // TODO (6b/6d): sendAudioPushNotification equivalent — OneSignal REST
    // call, ported alongside upload/push step so the API key handling
    // gets proper treatment in one place instead of scattered across files.
  }

  Future<void> markReadUpTo(int timestamp) async {
    if (timestamp <= _lastReadTimestamp) return;
    _lastReadTimestamp = timestamp;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('audio_screen_last_read_timestamp', timestamp);
  }

  @override
  void dispose() {
    _userChatsSub?.cancel();
    _textMessagesSub?.cancel();
    _reactionsSub?.cancel();
    _sermonsSub?.cancel();
    _deletedForMeSub?.cancel();
    super.dispose();
  }
}