import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

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
import '../data/sermon_audio.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _chatController = ScrollController();
  final _messageController = TextEditingController();

  String? _viewingImageUrl;
  ReplyTarget? _replyTarget;
  String? _longPressMenuFor;
  bool _initialScrollDone = false;

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
        artist: sermon.senderName,
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
        artist: sermon.senderName,
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    ResumableDownloader.instance.start(sermon.id, sermon.audioUrl, ext: '.mp3');
    _player.playUrl(
      id: sermon.id,
      title: title,
      url: sermon.audioUrl,
      artist: sermon.senderName,
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
        artist: sermon.senderName,
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
      artist: sermon.senderName,
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

  void _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    await _feed.sendTextMessage(
      text,
      replyToId: _replyTarget?.id,
      replyToType: _replyTarget?.type,
      replyToPreview: _replyTarget?.preview,
    );

    sendAudioPushNotification(
      senderName: _feed.currentSenderName,
      messageBody: text,
      senderUid: _feed.currentUid ?? '',
    );

    _messageController.clear();
    setState(() => _replyTarget = null);

    Future.delayed(const Duration(milliseconds: 200), () {
      final items = _feed.feedItems;
      if (items.isNotEmpty && _chatController.hasClients) {
        _chatController.animateTo(
          _chatController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
        _feed.markReadUpTo(items.last.timestamp);
      }
    });
  }

  void _scrollToBottomAndMarkRead() {
    final items = _feed.feedItems;
    if (items.isEmpty) return;
    if (_chatController.hasClients) {
      _chatController.animateTo(
        _chatController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    _feed.markReadUpTo(items.last.timestamp);
  }

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<AudioFeedProvider>();
    final feedItems = feed.feedItems;

    if (!_initialScrollDone && feedItems.isNotEmpty) {
      _initialScrollDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {});
    }

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
                const Text(
                  'TONKOH  BIBLE  TRUTH  REVEALERS',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF102A72)),
                ),
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
              child: AudioFeedList(
                feedItems: feedItems,
                scrollController: _chatController,
                reactionsMap: feed.reactionsMap,
                longPressMenuFor: _longPressMenuFor,
                onLongPress: (id) => setState(() => _longPressMenuFor = id),
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
                onImageClick: (url) => setState(() => _viewingImageUrl = url),
                onVideoTap: _handleVideoTap,
                unreadCount: feed.unreadCount,
                onJumpToBottom: _scrollToBottomAndMarkRead,
                viewingImageUrl: _viewingImageUrl,
                onDismissImage: () => setState(() => _viewingImageUrl = null),
              ),
            ),
            // Composer — last child of the body Column so `resizeToAvoidBottom
            // Inset` lifts it clear of the keyboard. It keeps its own
            // `SafeArea(top:false)` for the nav-bar inset.
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
    _chatController.dispose();
    _messageController.dispose();
    super.dispose();
  }
}
