import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_manager.dart';
import '../../data/feed_item.dart';
import '../../data/local_feed_store.dart';
import '../../data/local_hidden_store.dart';
import '../../data/sermon_audio.dart';
import '../../data/text_message.dart';
import '../../links/link_preview.dart';
import '../../services/resumable_downloader.dart';
import '../../util/startup_trace.dart';

/// Where the user stopped reading the Audio screen: the post anchored at
/// the bottom of the visible area and how far up from the bottom edge it
/// sat (0 = bottom, 1 = top), or "at the newest post".
@immutable
class FeedPosition {
  final String itemId;
  final int itemTimestamp;
  final double alignment;
  final bool atNewest;

  const FeedPosition({
    required this.itemId,
    required this.itemTimestamp,
    required this.alignment,
    required this.atNewest,
  });

  Map<String, Object?> toJson() => {
        'id': itemId,
        'ts': itemTimestamp,
        'a': alignment,
        'newest': atNewest,
      };

  static FeedPosition? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return FeedPosition(
        itemId: j['id'] as String,
        itemTimestamp: (j['ts'] as num).toInt(),
        alignment: (j['a'] as num).toDouble(),
        atNewest: j['newest'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where the Audio screen should open, given the saved [position] and the
/// current [items] (oldest first). Returns the index in the *reversed*
/// list the screen draws (0 = newest, at the bottom) and the alignment.
({int index, double alignment}) initialFeedScroll(
    List<FeedItem> items, FeedPosition? position) {
  if (items.isEmpty || position == null || position.atNewest) {
    return (index: 0, alignment: 0);
  }
  var i = items.indexWhere((f) => f.id == position.itemId);
  if (i == -1) {
    // That post is gone (deleted / hidden): the nearest older one.
    i = items.lastIndexWhere((f) => f.timestamp <= position.itemTimestamp);
    if (i == -1) i = 0;
  }
  return (
    index: items.length - 1 - i,
    alignment: position.alignment.clamp(0.0, 0.95).toDouble(),
  );
}

/// The first post newer than [lastReadTimestamp] (where the "N new
/// messages" divider goes) and how many such posts there are. No divider on
/// a first install (nothing read yet) or when nothing is new.
({String? firstUnreadId, int count}) unreadDivider(
    List<FeedItem> items, int lastReadTimestamp, {String? myUid}) {
  if (lastReadTimestamp <= 0) return (firstUnreadId: null, count: 0);
  String? first;
  var count = 0;
  for (final f in items) {
    if (f.timestamp <= lastReadTimestamp) continue;
    final sender = f.sermon?.senderId ?? f.textMessage?.senderId;
    if (myUid != null && sender == myUid) continue; // my own posts
    first ??= f.id;
    count++;
  }
  return (firstUnreadId: first, count: count);
}

/// The Audio screen's data: the approved feed (sermons/media/link posts and
/// text posts) and reactions, read from the phone's [LocalFeedStore].
///
/// Created once at app start (main.dart), so a background listener keeps
/// the local store current while the app runs and the screen always opens
/// from memory / disk. The network brings only what changed:
///  * new posts: `orderByChild('timestamp').startAfter(<newest stored>)`;
///  * edits and deletions of stored posts: child-changed/removed listeners;
///  * reactions: per-item child events instead of the whole map.
class AudioFeedProvider extends ChangeNotifier {
  AudioFeedProvider({LocalFeedStore? store})
      : _store = store ?? LocalFeedStore.instance;

  final LocalFeedStore _store;

  // ---------- Auth state ----------
  String? currentUid;
  String currentSenderName = '';
  String currentSenderPhone = '';

  // ---------- Feed data ----------
  final List<SermonAudio> _sermons = [];
  final List<TextMessage> _textMessages = [];
  final Map<String, Map<String, int>> reactionsMap = {};
  final Set<String> _hiddenIds = {};
  List<FeedItem>? _feedCache;

  /// True once the local store has been read (the first frame can draw).
  bool localLoaded = false;

  List<FeedItem> get feedItems => _feedCache ??=
      buildFeedItems(_sermons, _textMessages)
          .where((f) => !_hiddenIds.contains(f.id))
          .toList(growable: false);

  @override
  void notifyListeners() {
    _feedCache = null;
    super.notifyListeners();
  }

  /// "Delete for me" — hides a feed item on this device only.
  Future<void> hideLocally(String itemId) async {
    _hiddenIds.add(itemId);
    notifyListeners();
    await LocalHiddenStore.instance.hide(itemId);
  }

  // ---------- Unread (private chats) badge ----------
  int totalUnread = 0;

  // ---------- Feed read state ----------
  int _lastReadTimestamp = 0;
  int get lastReadTimestamp => _lastReadTimestamp;

  int get unreadCount =>
      unreadDivider(feedItems, _lastReadTimestamp, myUid: currentUid).count;

  // ---------- Reading position ----------
  FeedPosition? savedPosition;
  bool _positionLoaded = false;

  StreamSubscription? _userChatsSub;
  final List<StreamSubscription> _feedSubs = [];
  StreamSubscription? _localSermonsSub;
  StreamSubscription? _localTextsSub;
  StreamSubscription? _localReactionsSub;

  final _textMessagesRef = FirebaseDatabase.instance.ref('textMessages');
  final _reactionsRef = FirebaseDatabase.instance.ref('reactions');
  final _sermonsRef = FirebaseDatabase.instance.ref('sermons').child('approved');

  /// Posts whose clock was behind still arrive: new-post queries start this
  /// far before the newest stored post (duplicates are harmless upserts).
  static const int _clockSkewMs = 6 * 60 * 60 * 1000;

  static String _posKey(String? uid) => 'audio_feed_position_v1_${uid ?? ''}';
  static const String _lastReadKey = 'audio_screen_last_read_timestamp';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _lastReadTimestamp = prefs.getInt(_lastReadKey) ?? 0;
    _hiddenIds.addAll(await LocalHiddenStore.instance.hiddenIds());

    // Render from the phone first — instant and offline.
    final cached = AuthManager.lastKnownProfile ?? await AuthManager.getCachedProfile();
    _loadPosition(prefs, cached?.uid);
    final local = await _store.preload();
    _sermons
      ..clear()
      ..addAll(local.sermons.where((s) => s.isDisplayable));
    _textMessages
      ..clear()
      ..addAll(local.texts.where((m) => m.text.isNotEmpty));
    localLoaded = true;
    StartupTrace.markOnce('feedLocalLoaded');
    notifyListeners();
    _subscribeLocalCache();

    await AuthManager.ensureSignedIn(
      onReady: () async {
        final me = await AuthManager.getCachedProfile();
        if (me != null) {
          currentUid = me.uid;
          currentSenderName = me.name;
          currentSenderPhone = me.phone;
          if (!_positionLoaded) _loadPosition(prefs, me.uid);
          _watchUserChats(me.uid);
          notifyListeners();
        }
      },
      onError: (msg) => debugPrint('AudioFeedProvider: ensureSignedIn failed: $msg'),
    );

    await _startSync();
  }

  void _loadPosition(SharedPreferences prefs, String? uid) {
    if (uid == null) return;
    _positionLoaded = true;
    savedPosition = FeedPosition.fromJson(prefs.getString(_posKey(uid)));
  }

  /// Called by the Audio screen as the user scrolls / leaves.
  Future<void> savePosition(FeedPosition position) async {
    savedPosition = position;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_posKey(currentUid), jsonEncode(position.toJson()));
  }

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


  /// Live view of the local store — what the UI reads.
  void _subscribeLocalCache() {
    _localSermonsSub = _store.observeSermons().listen((rows) {
      _sermons
        ..clear()
        ..addAll(rows.where((s) => s.isDisplayable));
      notifyListeners();
    });
    _localTextsSub = _store.observeTexts().listen((rows) {
      _textMessages
        ..clear()
        ..addAll(rows.where((m) => m.text.isNotEmpty));
      notifyListeners();
    });
    _localReactionsSub = _store.observeReactions().listen((map) {
      reactionsMap
        ..clear()
        ..addAll(map);
      notifyListeners();
    });
  }

  // Incoming rows are written in small batches (one DB write + one UI
  // update per burst, not per post).
  final List<SermonAudio> _pendingSermons = [];
  final List<TextMessage> _pendingTexts = [];
  Timer? _flushTimer;

  void _queue({SermonAudio? sermon, TextMessage? text}) {
    if (sermon != null) _pendingSermons.add(sermon);
    if (text != null) _pendingTexts.add(text);
    _flushTimer ??= Timer(const Duration(milliseconds: 80), _flush);
  }

  Future<void> _flush() async {
    _flushTimer = null;
    final s = List.of(_pendingSermons);
    final t = List.of(_pendingTexts);
    _pendingSermons.clear();
    _pendingTexts.clear();
    await _store.upsertSermons(s);
    await _store.upsertTexts(t);
  }

  Future<void> _startSync() async {
    final newest = await _store.latestTimestamp();
    final since = newest <= 0 ? null : newest - _clockSkewMs;

    // Sermons / media / link posts (sermons/approved).
    final newSermons = since == null
        ? _sermonsRef.orderByChild('timestamp')
        : _sermonsRef.orderByChild('timestamp').startAfter(since);
    _feedSubs.addAll([
      newSermons.onChildAdded.listen((e) => _onSermon(e.snapshot),
          onError: (e) => debugPrint('RTDB sermons error: $e')),
      _sermonsRef.onChildChanged.listen((e) => _onSermon(e.snapshot),
          onError: (_) {}),
      _sermonsRef.onChildRemoved.listen((e) {
        final id = e.snapshot.key;
        if (id != null) _store.deleteSermon(id);
      }, onError: (_) {}),
    ]);

    // Text posts. Edits / deletions are watched on the most recent ones.
    final newTexts = since == null
        ? _textMessagesRef.orderByChild('timestamp').limitToLast(200)
        : _textMessagesRef.orderByChild('timestamp').startAfter(since);
    final recentTexts = _textMessagesRef.orderByChild('timestamp').limitToLast(100);
    _feedSubs.addAll([
      newTexts.onChildAdded.listen((e) => _onText(e.snapshot),
          onError: (e) => debugPrint('RTDB textMessages error: $e')),
      recentTexts.onChildChanged.listen((e) => _onText(e.snapshot),
          onError: (_) {}),
      recentTexts.onChildRemoved.listen((e) {
        final id = e.snapshot.key;
        if (id != null) _store.deleteText(id);
      }, onError: (_) {}),
    ]);

    // Reactions, one item at a time.
    void onReaction(DataSnapshot snap, {bool removed = false}) {
      final id = snap.key;
      if (id == null) return;
      final counts = <String, int>{};
      final v = snap.value;
      if (!removed && v is Map) {
        v.forEach((emoji, n) => counts[emoji.toString()] = (n as num?)?.toInt() ?? 0);
      }
      _store.setItemReactions(id, counts);
    }

    _feedSubs.addAll([
      _reactionsRef.onChildAdded.listen((e) => onReaction(e.snapshot),
          onError: (e) => debugPrint('RTDB reactions error: $e')),
      _reactionsRef.onChildChanged.listen((e) => onReaction(e.snapshot),
          onError: (_) {}),
      _reactionsRef.onChildRemoved.listen(
          (e) => onReaction(e.snapshot, removed: true),
          onError: (_) {}),
    ]);
  }

  void _onSermon(DataSnapshot snap) {
    final id = snap.key;
    final v = snap.value;
    if (id == null || v is! Map) return;
    final sermon = SermonAudio.fromMap(id, v);
    if (sermon.isDisplayable) _queue(sermon: sermon);
  }

  void _onText(DataSnapshot snap) {
    final id = snap.key;
    final v = snap.value;
    if (id == null || v is! Map) return;
    final msg = TextMessage.fromMap(id, v);
    if (msg.text.isNotEmpty) _queue(text: msg);
  }

  void addReaction(String itemId, String emoji) {
    _reactionsRef.child(itemId).child(emoji).set(ServerValue.increment(1));
  }

  /// Admin hard-delete (removes for everyone). "Delete for me" is
  /// [hideLocally].
  void deleteItem(String itemId, String itemType) {
    if (itemType == 'audio') {
      _sermonsRef.child(itemId).remove();
      _store.deleteSermon(itemId);
      ResumableDownloader.instance.discard(itemId);
    } else {
      _textMessagesRef.child(itemId).remove();
      _store.deleteText(itemId);
    }
    _reactionsRef.child(itemId).remove();
  }

  Future<void> sendTextMessage(
    String text, {
    String? replyToId,
    String? replyToType,
    String? replyToPreview,
    LinkPreview? link,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final newRef = _textMessagesRef.push();
    final msg = TextMessage(
      id: newRef.key ?? '',
      text: trimmed,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      replyToId: replyToId ?? '',
      replyToType: replyToType ?? '',
      replyToPreview: replyToPreview ?? '',
      senderId: currentUid ?? '',
      senderName: currentSenderName,
      senderPhone: currentSenderPhone,
      link: link,
    );
    // Shown at once from the phone; the listener confirms it later.
    unawaited(_store.upsertText(msg));
    await newRef.set(msg.toMap());
  }

  Future<void> markReadUpTo(int timestamp) async {
    if (timestamp <= _lastReadTimestamp) return;
    _lastReadTimestamp = timestamp;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastReadKey, timestamp);
  }

  @override
  void dispose() {
    _userChatsSub?.cancel();
    _flushTimer?.cancel();
    for (final s in _feedSubs) {
      s.cancel();
    }
    _localSermonsSub?.cancel();
    _localTextsSub?.cancel();
    _localReactionsSub?.cancel();
    super.dispose();
  }
}
