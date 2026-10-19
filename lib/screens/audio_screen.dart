import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../calls/start_call.dart';
import '../data/app_contact.dart';
import '../data/contact_sync_service.dart';
import '../data/display_names.dart';
import '../data/profile_photo_cache.dart';
import 'auth/auth_manager.dart';
import 'components/contact_action_sheet.dart';

import '../cloudinary/cloudinary_upload.dart';
import '../screens/audio/audio_feed_provider.dart';
import '../screens/audio/global_audio_player.dart';
import '../screens/audio/onesignal_push.dart';
import '../screens/media/network_video_screen.dart';
import '../services/resumable_downloader.dart';
import '../services/share_service.dart';
import '../screens/audio/audio_bottom_bar.dart';
import '../screens/audio/audio_drawer_content.dart';
import '../screens/audio/audio_feed_list.dart';
import '../screens/audio/reply_target.dart';
import '../screens/audio/upload_sheet.dart';
import '../data/feed_item.dart';
import '../data/sermon_audio.dart';
import '../links/link_preview.dart';
import '../links/typed_link_preview.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _itemScroll = ItemScrollController();
  final _itemPositions = ItemPositionsListener.create();
  final _messageController = TextEditingController();

  String? _viewingImageUrl;
  ReplyTarget? _replyTarget;
  String? _longPressMenuFor;
  LinkPreview? _composerLink;

  // Decided once per visit, from the phone's copy of the feed: where the
  // list opens and where the "N new messages" divider sits.
  bool _opened = false;
  int _initialIndex = 0;
  double _initialAlignment = 0;
  String? _dividerId;
  int _dividerCount = 0;
  final Stopwatch _openWatch = Stopwatch()..start();

  // The post anchored at the bottom of the view, kept in place when new
  // posts are added below it.
  String? _anchorId;
  double _anchorAlignment = 0;
  bool _atNewest = true;
  int _lastItemCount = 0;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _itemPositions.itemPositions.addListener(_onPositions);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _savePosition();
    }
  }

  void _openFrom(AudioFeedProvider feed) {
    final items = feed.feedItems;
    final start = initialFeedScroll(items, feed.savedPosition);
    _initialIndex = start.index;
    _initialAlignment = start.alignment;
    final divider =
        unreadDivider(items, feed.lastReadTimestamp, myUid: feed.currentUid);
    _dividerId = divider.firstUnreadId;
    _dividerCount = divider.count;
    _atNewest = start.index == 0;
    _lastItemCount = items.length;
    if (items.isNotEmpty) {
      _anchorId = items[items.length - 1 - start.index].id;
      _anchorAlignment = start.alignment;
    }
    // First install: everything already there counts as read.
    if (feed.lastReadTimestamp <= 0 && items.isNotEmpty) {
      feed.markReadUpTo(items.last.timestamp);
    }
    _opened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[FeedOpen] ${items.length} posts visible after '
          '${_openWatch.elapsedMilliseconds} ms (from the phone)');
    });
  }

  /// Tracks the bottom-most visible post, marks what is seen as read, and
  /// saves the position shortly after scrolling stops.
  void _onPositions() {
    final items = _feed.feedItems;
    final positions = _itemPositions.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .toList();
    if (items.isEmpty || positions.isEmpty) return;
    positions.sort((a, b) => a.index.compareTo(b.index));
    final bottom = positions.first;
    final i = items.length - 1 - bottom.index;
    if (i < 0 || i >= items.length) return;
    _anchorId = items[i].id;
    _anchorAlignment = bottom.itemLeadingEdge.clamp(0.0, 0.95).toDouble();
    _atNewest = bottom.index == 0 && bottom.itemLeadingEdge <= 0.02;
    _feed.markReadUpTo(items[i].timestamp);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _savePosition);
  }

  void _savePosition() {
    final id = _anchorId;
    if (id == null || !mounted) return;
    final item = _feed.feedItems.where((f) => f.id == id).firstOrNull;
    if (item == null) return;
    _feed.savePosition(FeedPosition(
      itemId: id,
      itemTimestamp: item.timestamp,
      alignment: _anchorAlignment,
      atNewest: _atNewest,
    ));
  }

  /// New posts were added at the bottom while I'm reading further up: keep
  /// the same post at the same place (the reversed list's indices shifted).
  void _keepAnchor(List<FeedItem> items) {
    if (items.length == _lastItemCount) return;
    _lastItemCount = items.length;
    if (_atNewest || _anchorId == null) return;
    final i = items.indexWhere((f) => f.id == _anchorId);
    if (i == -1) return;
    final index = items.length - 1 - i;
    final alignment = _anchorAlignment;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_itemScroll.isAttached) {
        _itemScroll.jumpTo(index: index, alignment: alignment);
      }
    });
  }

  AudioFeedProvider get _feed => context.read<AudioFeedProvider>();
  GlobalAudioPlayer get _player => context.read<GlobalAudioPlayer>();

  void _handleAudioPlayPauseClick(SermonAudio sermon) async {
    final isSame = _player.nowPlaying?.id == sermon.id;

    if (isSame && _player.isPlaying) return _player.pause();
    if (isSame && !_player.isPlaying) return _player.resume();

    final title = sermon.title.isEmpty ? 'Untitled' : sermon.title;

    // Web can't cache to a local file (no path_provider support there) —
    // stream directly from the Cloudinary URL instead.
    if (kIsWeb) {
      _player.playUrl(
        id: sermon.id,
        title: title,
        url: sermon.audioUrl,
        artist: DisplayNames.instance.nameFor(sermon.senderId),
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    // Play from the offline copy if one exists; otherwise stream
    // progressively from the URL AND kick a background save so this first
    // play is the only time it's fetched — replays (and offline) then come
    // from disk. No audio is downloaded until the user taps play.
    final saved =
        await ResumableDownloader.instance.completedFile(sermon.id, '.mp3');
    if (saved != null) {
      _player.play(
        id: sermon.id,
        title: title,
        filePath: saved.path,
        artist: DisplayNames.instance.nameFor(sermon.senderId),
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    ResumableDownloader.instance.start(sermon.id, sermon.audioUrl, ext: '.mp3');
    _player.playUrl(
      id: sermon.id,
      title: title,
      url: sermon.audioUrl,
      artist: DisplayNames.instance.nameFor(sermon.senderId),
      onComplete: () => _playNextInSequence(sermon.id),
    );
  }

  void _playNextInSequence(String afterId) async {
    final items = _feed.feedItems;
    final idx = items.indexWhere((f) => f.id == afterId);
    if (idx == -1 || idx + 1 >= items.length) return;

    final next = items[idx + 1];
    if (next.type != 'audio' || next.sermon == null) return;
    final sermon = next.sermon!;
    if (sermon.mediaType != 'AUDIO') return;

    if (kIsWeb) {
      _player.playUrl(
        id: sermon.id,
        title: sermon.title.isEmpty ? 'Untitled' : sermon.title,
        url: sermon.audioUrl,
        artist: DisplayNames.instance.nameFor(sermon.senderId),
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    final saved =
        await ResumableDownloader.instance.completedFile(sermon.id, '.mp3');
    if (saved == null) return; // only auto-advances to already-saved tracks

    _player.play(
      id: sermon.id,
      title: sermon.title.isEmpty ? 'Untitled' : sermon.title,
      filePath: saved.path,
      artist: DisplayNames.instance.nameFor(sermon.senderId),
      onComplete: () => _playNextInSequence(sermon.id),
    );
  }

  /// Share an audio sermon as the actual mp3 file. If it's already cached
  /// (played or downloaded before) the native sheet opens immediately; if
  /// not, the tap gets instant feedback (a snackbar) while the file is
  /// fetched on demand — the same download the play button uses, never a
  /// second one — then the sheet opens. Falls back to the app link if the
  /// download can't complete.
  bool _sharePreparing = false;

  Future<void> _shareAudio(SermonAudio sermon) async {
    if (_sharePreparing) return;
    final title = sermon.title.isEmpty ? 'Audio' : sermon.title;
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      ShareService.instance.shareApp(message: title);
      return;
    }

    final cached =
        await ResumableDownloader.instance.completedFile(sermon.id, '.mp3');
    if (cached != null) {
      await ShareService.instance
          .shareAudioFile(filePath: cached.path, title: title);
      return;
    }

    _sharePreparing = true;
    messenger.showSnackBar(const SnackBar(
      content: Text('Preparing audio to share…'),
      duration: Duration(seconds: 10),
    ));
    try {
      final file = await ResumableDownloader.instance
          .ensureComplete(sermon.id, sermon.audioUrl, ext: '.mp3');
      messenger.hideCurrentSnackBar();
      if (file != null) {
        await ShareService.instance
            .shareAudioFile(filePath: file.path, title: title);
      } else {
        await ShareService.instance.shareApp(message: title);
      }
    } catch (_) {
      messenger.hideCurrentSnackBar();
      await ShareService.instance.shareApp(message: title);
    } finally {
      _sharePreparing = false;
    }
  }

  /// Share a video sermon as the actual video file. Same rules as
  /// [_shareAudio]: cached → sheet opens immediately; uncached → a
  /// "Preparing…" snackbar, then the file is streamed to disk (resumable,
  /// reusing any in-flight download) and shared; falls back to the app link
  /// if it can't be prepared. The old path re-downloaded the whole video
  /// into memory on every tap with no feedback — that's the slowness.
  Future<void> _shareVideo(SermonAudio sermon) async {
    if (_sharePreparing) return;
    final title = sermon.title.isEmpty ? 'Video' : sermon.title;
    final thumb = cloudinaryVideoThumbnail(sermon.audioUrl);
    final messenger = ScaffoldMessenger.of(context);

    if (kIsWeb) {
      ShareService.instance.shareApp(message: title);
      return;
    }

    final cached =
        await ResumableDownloader.instance.completedFile(sermon.id, '.mp4');
    if (cached != null) {
      await ShareService.instance.shareVideo(
        title: title,
        localFilePath: cached.path,
      );
      return;
    }

    _sharePreparing = true;
    messenger.showSnackBar(const SnackBar(
      content: Text('Preparing video to share…'),
      duration: Duration(seconds: 30),
    ));
    try {
      final file = await ResumableDownloader.instance
          .ensureComplete(sermon.id, sermon.audioUrl, ext: '.mp4');
      messenger.hideCurrentSnackBar();
      if (file != null) {
        await ShareService.instance.shareVideo(
          title: title,
          localFilePath: file.path,
          thumbnailUrl: thumb,
        );
      } else {
        await ShareService.instance.shareApp(message: title);
      }
    } catch (_) {
      messenger.hideCurrentSnackBar();
      await ShareService.instance.shareApp(message: title);
    } finally {
      _sharePreparing = false;
    }
  }

  void _handleVideoTap(SermonAudio sermon) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NetworkVideoScreen(
        url: sermon.audioUrl,
        cacheKey: sermon.id,
        title: sermon.title.isEmpty ? 'Video' : sermon.title,
      ),
    ));
  }

  /// Tapped a member's photo or name in the feed — WhatsApp group style:
  /// see their number and reach them privately. Nothing here touches the
  /// feed: a private chat or call is only between the two of us.
  void _openMemberSheet(String senderId, ReplyTarget replyTarget) {
    final names = DisplayNames.instance;
    final contact = AppContact(
      name: names.nameFor(senderId),
      phone: senderId,
      uid: senderId,
      photoUrl: ProfilePhotoCache.instance.photoFor(senderId),
      source: 'FEED',
    );
    showContactActionSheet(
      context: context,
      contact: contact,
      messageLabel: 'Message privately',
      onMessage: (c) => context.push('/privateChat/${c.uid}'),
      onVoiceCall: (c) => _callMember(c, 'audio'),
      onVideoCall: (c) => _callMember(c, 'video'),
      onReply: () => setState(() => _replyTarget = replyTarget),
      onSaveContact: names.isSaved(senderId) ? null : _saveMemberContact,
    );
  }

  Future<void> _callMember(AppContact member, String callType) async {
    final me = await AuthManager.getCachedProfile();
    if (!mounted) return;
    if (me == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Finishing sign-in — try again in a moment.')),
      );
      return;
    }
    await startPrivateAppCall(
      context: context,
      caller: me,
      calleeUid: member.uid!,
      calleeName: member.name,
      callType: callType,
    );
  }

  /// Opens the phone's own "new contact" screen with the number filled in;
  /// the contact sync picks the new name up as soon as it's saved.
  Future<void> _saveMemberContact(AppContact member) async {
    try {
      await FlutterContacts.native.showCreator(
        contact: Contact(phones: [Phone(number: member.phone)]),
      );
    } catch (e) {
      debugPrint('AudioScreen: showCreator failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open your contacts app.")),
        );
      }
      return;
    }
    unawaited(ContactSyncService.instance.sync());
  }

  void _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final link = _composerLink;
    await _feed.sendTextMessage(
      text,
      replyToId: _replyTarget?.id,
      replyToType: _replyTarget?.type,
      replyToPreview: _replyTarget?.preview,
      link: link != null && text.contains(link.url) ? link : null,
    );

    sendAudioPushNotification(
      senderName: _feed.currentSenderName,
      messageBody: text,
      senderUid: _feed.currentUid ?? '',
    );

    _messageController.clear();
    setState(() {
      _replyTarget = null;
      _composerLink = null;
    });
    Future.delayed(
        const Duration(milliseconds: 200), _scrollToBottomAndMarkRead);
  }

  void _scrollToBottomAndMarkRead() {
    final items = _feed.feedItems;
    if (items.isEmpty || !mounted) return;
    _atNewest = true;
    if (_itemScroll.isAttached) {
      _itemScroll.scrollTo(
        index: 0,
        alignment: 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    _feed.markReadUpTo(items.last.timestamp);
    setState(() => _dividerId = null);
  }

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<AudioFeedProvider>();
    final feedItems = feed.feedItems;

    if (!_opened && feed.localLoaded) _openFrom(feed);
    if (_opened) _keepAnchor(feedItems);

    return Scaffold(
      key: _scaffoldKey,
      // Keep the composer visible above the keyboard. A Scaffold does NOT
      // lift its `bottomNavigationBar` above the keyboard — it stays pinned
      // to the physical bottom and the IME covers it (the reported bug). So
      // the composer lives at the end of the body Column instead, and the
      // resized body pushes it up when the keyboard opens.
      resizeToAvoidBottomInset: true,
      drawer: Drawer(
        child: AudioDrawerContent(
          currentUid: feed.currentUid,
          totalUnread: feed.totalUnread,
          onNavigateContacts: () => context.push('/contact'),
          onNavigateBibleFacts: () => context.push('/message'),
          onNavigateFeedback: () => context.push('/feedback'),
          onNavigateAdmin: () => context.push('/admin'),
          onNavigateDiscussions: () => context.push('/chatList'),
          onNavigateSettings: () => context.push('/settings'),
          onClose: () => Navigator.pop(context),
        ),
      ),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(44),
        child: Container(
          color: const Color(0xFFE3F2FD),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.menu, color: Color(0xFF102A72)),
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    ),
                    if (feed.totalUnread > 0)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE53935),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            feed.totalUnread > 99
                                ? '99+'
                                : '${feed.totalUnread}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                  ],
                ),
                const Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'TONKOH  BIBLE  TRUTH  REVEALERS',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF102A72)),
                    ),
                  ),
                ),
                // Never blocks the screen — just says what the feed is doing.
                if (!feed.online)
                  const _SyncChip(label: 'Offline', icon: Icons.cloud_off)
                else if (feed.updating)
                  const _SyncChip(label: 'Updating…', icon: Icons.sync),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF00BCD4), Color(0xFF79DF7D), Color(0xFFF7EB88)],
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 4),
            const Text(
              'Listen, read, and join the conversation.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFE3F2FD), fontSize: 12),
            ),
            const SizedBox(height: 4),
            Expanded(
              // Drawn once the phone's copy is read (a few ms after launch)
              // so it opens at the right post, never at the top.
              child: !_opened
                  ? const SizedBox.shrink()
                  : AudioFeedList(
                      feedItems: feedItems,
                      itemScrollController: _itemScroll,
                      itemPositionsListener: _itemPositions,
                      initialScrollIndex: _initialIndex,
                      initialAlignment: _initialAlignment,
                      unreadDividerId: _dividerId,
                      unreadDividerCount: _dividerCount,
                      reactionsMap: feed.reactionsMap,
                      longPressMenuFor: _longPressMenuFor,
                      onLongPress: (id) =>
                          setState(() => _longPressMenuFor = id),
                      onDismissLongPressMenu: () =>
                          setState(() => _longPressMenuFor = null),
                      onReact: (itemId, emoji) {
                        feed.addReaction(itemId, emoji);
                        setState(() => _longPressMenuFor = null);
                      },
                      onReply: (target) => setState(() {
                        _replyTarget = target;
                        _longPressMenuFor = null;
                      }),
                      onDelete: (itemId, _) => feed.hideLocally(itemId),
                      onAudioPlayPauseClick: _handleAudioPlayPauseClick,
                      onShareAudio: _shareAudio,
                      onShareVideo: _shareVideo,
                      onSeekChange: (sermon, value) {
                        if (_player.nowPlaying?.id == sermon.id) {
                          _player.beginScrub();
                          _player.positionMs = value.toInt();
                        }
                      },
                      onSeekFinished: (sermon) {
                        if (_player.nowPlaying?.id == sermon.id) {
                          _player.seekTo(_player.positionMs);
                        }
                      },
                      onImageClick: (url) =>
                          setState(() => _viewingImageUrl = url),
                      onVideoTap: _handleVideoTap,
                      unreadCount: feed.unreadCount,
                      onJumpToBottom: _scrollToBottomAndMarkRead,
                      viewingImageUrl: _viewingImageUrl,
                      onDismissImage: () =>
                          setState(() => _viewingImageUrl = null),
                      currentUid: feed.currentUid,
                      onSenderTap: _openMemberSheet,
                    ),
            ),
            // Composer — last child of the body Column so `resizeToAvoidBottom
            // Inset` lifts it clear of the keyboard. It keeps its own
            // `SafeArea(top:false)` for the nav-bar inset.
            TypedLinkPreview(
              controller: _messageController,
              onChanged: (p) => _composerLink = p,
            ),
            AudioBottomBar(
              controller: _messageController,
              onSend: _sendTextMessage,
              onUploadClick: () => showUploadPickMenu(context),
              replyTargetText: _replyTarget?.preview,
              onCancelReply: () => setState(() => _replyTarget = null),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _savePosition();
    _saveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _itemPositions.itemPositions.removeListener(_onPositions);
    _messageController.dispose();
    super.dispose();
  }
}

class _SyncChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SyncChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x1A102A72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: const Color(0xFF102A72)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF102A72))),
      ]),
    );
  }
}
