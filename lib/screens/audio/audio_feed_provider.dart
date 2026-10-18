import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';
import '../auth/auth_manager.dart';
import '../../data/feed_item.dart';
import '../../data/local_feed_store.dart';
import '../../data/local_hidden_store.dart';
import '../../data/sermon_audio.dart';
import '../../data/text_message.dart';
import '../../services/resumable_downloader.dart';

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

  final Set<String> _hiddenIds = {};

  List<FeedItem> get feedItems => buildFeedItems(_sermons, _textMessages)
      .where((f) => !_hiddenIds.contains(f.id))
      .toList();

  /// "Delete for me" — hides a feed item on this device only. The item
  /// stays in Firebase for everyone else.
  Future<void> hideLocally(String itemId) async {
    _hiddenIds.add(itemId);
    notifyListeners();
    await LocalHiddenStore.instance.hide(itemId);
  }

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

  // Local cache (source of truth for the UI). Firebase listeners above just
  // upsert into LocalFeedStore; these subscriptions feed the in-memory
  // lists the UI reads.
  StreamSubscription? _localSermonsSub;
  StreamSubscription? _localTextsSub;
  StreamSubscription? _localReactionsSub;

  final _textMessagesRef = FirebaseDatabase.instance.ref('textMessages');
  final _reactionsRef = FirebaseDatabase.instance.ref('reactions');
  final _sermonsRef =
  FirebaseDatabase.instance.ref('sermons').child('approved');

  /// Call once when the screen mounts (equivalent of the two
  /// LaunchedEffect(Unit) blocks in AudioScreen.kt).
  Future<void> init() async {
    await _loadLastReadTimestamp();
    _hiddenIds.addAll(await LocalHiddenStore.instance.hiddenIds());

    // Render from the local cache first — instant and offline-capable. The
    // Firebase listeners below only write into that same cache.
    _subscribeLocalCache();

    await AuthManager.ensureSignedIn(
      onReady: () async {
        final cached = await AuthManager.getCachedProfile();
        if (cached != null) {
          currentUid = cached.uid;
          currentSenderName = cached.name;
          currentSenderPhone = cached.phone;
          _watchUserChats(cached.uid);
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

  /// Live view of the local cache. This — not the Firebase snapshot — is
  /// what `feedItems` (and therefore the UI) reads, so the feed renders
  /// instantly and works with no connectivity.
  void _subscribeLocalCache() {
    _localSermonsSub = LocalFeedStore.instance.observeSermons().listen((rows) {
      _sermons
        ..clear()
        ..addAll(rows);
      notifyListeners();
    });
    _localTextsSub = LocalFeedStore.instance.observeTexts().listen((rows) {
      _textMessages
        ..clear()
        ..addAll(rows.where((m) => m.text.isNotEmpty));
      notifyListeners();
    });
    _localReactionsSub =
        LocalFeedStore.instance.observeReactions().listen((map) {
      reactionsMap
        ..clear()
        ..addAll(map);
      notifyListeners();
    });
  }

  /// Firebase is the sync source only: every incoming feed post is upserted
  /// into `LocalFeedStore`, and the UI updates from the local stream above.
  /// Upsert-only — a node missing from the snapshot (offline, or aged out of
  /// `limitToLast`) must never delete local history.
  void _watchTextMessages() {
    _textMessagesSub = _textMessagesRef
        .orderByChild('timestamp')
        .limitToLast(50)
        .onValue
        .listen((event) {
      final value = event.snapshot.value;
      if (value is! Map) return;
      final parsed = <TextMessage>[];
      value.forEach((key, child) {
        if (child is Map) {
          final msg = TextMessage.fromMap(key as String, child);
          if (msg.text.isNotEmpty) parsed.add(msg);
        }
      });
      LocalFeedStore.instance.upsertTexts(parsed);
    }, onError: (e) => debugPrint('RTDB textMessages error: $e'));
  }

  void _watchReactions() {
    _reactionsSub = _reactionsRef.onValue.listen((event) {
      final value = event.snapshot.value;
      // Not a Map == empty / offline placeholder — keep the cached counts
      // rather than wiping them.
      if (value is! Map) return;
      final newMap = <String, Map<String, int>>{};
      value.forEach((itemKey, emojiMap) {
        if (emojiMap is Map) {
          final inner = <String, int>{};
          emojiMap.forEach((emojiKey, count) {
            inner[emojiKey as String] = (count as num?)?.toInt() ?? 0;
          });
          newMap[itemKey as String] = inner;
        }
      });
      LocalFeedStore.instance.replaceReactions(newMap);
    }, onError: (e) => debugPrint('RTDB reactions error: $e'));
  }

  /// Mirrors dbRef.orderByChild("timestamp") on sermons/approved.
  void _watchSermons() {
    _sermonsSub = _sermonsRef.orderByChild('timestamp').onValue.listen((event) {
      final value = event.snapshot.value;
      if (value is! Map) return;
      final parsed = <SermonAudio>[];
      value.forEach((key, child) {
        if (child is Map) {
          final sermon = SermonAudio.fromMap(key as String, child);
          if (sermon.audioUrl.isNotEmpty) parsed.add(sermon);
        }
      });
      LocalFeedStore.instance.upsertSermons(parsed);
      // Metadata only. Audio bytes are fetched on demand when the user taps
      // play (see audio_screen._handleAudioPlayPauseClick), never eagerly
      // on list load.
    }, onError: (e) => debugPrint('RTDB sermons error: $e'));
  }

  void addReaction(String itemId, String emoji) {
    _reactionsRef.child(itemId).child(emoji).set(ServerValue.increment(1));
  }

  /// Admin hard-delete (removes for everyone). "Delete for me" is
  /// [hideLocally]. Clears the Firebase node, the local cache row, and —
  /// for audio — the cached mp3 / any partial download.
  void deleteItem(String itemId, String itemType) {
    if (itemType == 'audio') {
      _sermonsRef.child(itemId).remove();
      LocalFeedStore.instance.deleteSermon(itemId);
      ResumableDownloader.instance.discard(itemId);
    } else {
      _textMessagesRef.child(itemId).remove();
      LocalFeedStore.instance.deleteText(itemId);
    }
    _reactionsRef.child(itemId).remove();
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
    // The broadcast push for this message is sent by the caller
    // (AudioScreen._sendTextMessage → sendAudioPushNotification).
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
    _localSermonsSub?.cancel();
    _localTextsSub?.cancel();
    _localReactionsSub?.cancel();
    super.dispose();
  }
}