import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../screens/audio/audio_feed_provider.dart';
import '../screens/audio/global_audio_player.dart';
import '../screens/audio/audio_downloader.dart';
import '../screens/audio/onesignal_push.dart';
import '../data/feed_item.dart';
import '../screens/audio/audio_bottom_bar.dart';
import '../screens/audio/audio_drawer_content.dart';
import '../screens/audio/audio_feed_list.dart';
import '../screens/audio/reply_target.dart';
import '../screens/audio/video_player_screen.dart';
import '../data/sermon_audio.dart';
import '../services/share_service.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _chatController = ScrollController();
  final _messageController = TextEditingController();

  String? _downloadingId;
  int _downloadProgress = 0;
  AudioDownloadHandle? _activeAudioDownload;

  String? _downloadingVideoId;
  int _videoDownloadProgress = 0;
  AudioDownloadHandle? _activeVideoDownload;

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

    // Web can't cache to a local file (no path_provider support there) —
    // stream directly from the Cloudinary URL instead.
    if (kIsWeb) {
      _player.playUrl(
        id: sermon.id,
        title: sermon.title.isEmpty ? 'Untitled' : sermon.title,
        url: sermon.audioUrl,
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    final file = await localAudioFile(sermon.id);
    if (await file.exists()) {
      _player.play(
        id: sermon.id,
        title: sermon.title.isEmpty ? 'Untitled' : sermon.title,
        filePath: file.path,
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    final wasPlayingBefore = _player.isPlaying;
    setState(() => _downloadingId = sermon.id);

    _activeAudioDownload = downloadAudio(
      audioId: sermon.id,
      url: sermon.audioUrl,
      onProgress: (p) => setState(() => _downloadProgress = p),
      onComplete: (path) {
        setState(() {
          _downloadingId = null;
          _activeAudioDownload = null;
        });
        if (!wasPlayingBefore && !_player.isPlaying) {
          _player.play(
            id: sermon.id,
            title: sermon.title.isEmpty ? 'Untitled' : sermon.title,
            filePath: path,
            onComplete: () => _playNextInSequence(sermon.id),
          );
        }
      },
      onError: (_) => setState(() {
        _downloadingId = null;
        _activeAudioDownload = null;
      }),
      onCancelled: () => setState(() {
        _downloadingId = null;
        _activeAudioDownload = null;
      }),
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
        onComplete: () => _playNextInSequence(sermon.id),
      );
      return;
    }

    final file = await localAudioFile(sermon.id);
    if (!await file.exists()) return; // matches Kotlin: only plays if already cached

    _player.play(
      id: sermon.id,
      title: sermon.title.isEmpty ? 'Untitled' : sermon.title,
      filePath: file.path,
      onComplete: () => _playNextInSequence(sermon.id),
    );
  }

  void _handleVideoTap(SermonAudio sermon) async {
    // path_provider (used by localAudioFile below) has no web
    // implementation at all — calling it on web threw immediately, inside
    // an unawaited async callback, so tapping a video on web silently did
    // nothing. Web has no local file cache anyway; stream straight from
    // the hosted URL instead of downloading first.
    if (kIsWeb) {
      _openVideoPlayer(source: sermon.audioUrl, title: sermon.title, isFile: false, sermon: sermon);
      return;
    }

    final file = await localAudioFile(sermon.id);
    if (await file.exists()) {
      _openVideoPlayer(source: file.path, title: sermon.title, isFile: true, sermon: sermon);
      return;
    }
    setState(() => _downloadingVideoId = sermon.id);
    _activeVideoDownload = downloadAudio(
      audioId: sermon.id,
      url: sermon.audioUrl,
      onProgress: (p) => setState(() => _videoDownloadProgress = p),
      onComplete: (path) {
        setState(() {
          _downloadingVideoId = null;
          _activeVideoDownload = null;
        });
        _openVideoPlayer(source: path, title: sermon.title, isFile: true, sermon: sermon);
      },
      onError: (_) => setState(() {
        _downloadingVideoId = null;
        _activeVideoDownload = null;
      }),
      onCancelled: () => setState(() {
        _downloadingVideoId = null;
        _activeVideoDownload = null;
      }),
    );
  }

  void _openVideoPlayer({
    required String source,
    required String title,
    required bool isFile,
    SermonAudio? sermon,
  }) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(source: source, title: title, isFile: isFile, sermon: sermon),
    ));
  }

  void _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final replyTarget = _replyTarget;

    // Clear input + reply state immediately, before the RTDB write below —
    // previously this happened only after the await resolved, so the typed
    // text sat visible in the field for as long as the network write took
    // (most noticeable on web).
    _messageController.clear();
    setState(() => _replyTarget = null);

    await _feed.sendTextMessage(
      text,
      replyToId: replyTarget?.id,
      replyToType: replyTarget?.type,
      replyToPreview: replyTarget?.preview,
    );

    sendAudioPushNotification(
      senderName: _feed.currentSenderName,
      messageBody: text,
      senderUid: _feed.currentUid ?? '',
    );

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
      // Explicit (matches the default) — the body, including the input bar
      // moved into it below, resizes correctly above the keyboard this way.
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
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE53935),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            feed.totalUnread > 99 ? '99+' : '${feed.totalUnread}',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                  ],
                ),
                const Text(
                  'TONKOH  BIBLE  TRUTH  REVEALERS',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF102A72)),
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
                onDismissLongPressMenu: () => setState(() => _longPressMenuFor = null),
                onReact: (itemId, emoji) {
                  feed.addReaction(itemId, emoji);
                  setState(() => _longPressMenuFor = null);
                },
                onReply: (target) => setState(() {
                  _replyTarget = target;
                  _longPressMenuFor = null;
                }),
                onDelete: (itemId) => feed.deleteItemForMe(itemId),
                downloadingId: _downloadingId,
                downloadProgress: _downloadProgress,
                downloadingVideoId: _downloadingVideoId,
                videoDownloadProgress: _videoDownloadProgress,
                onAudioPlayPauseClick: _handleAudioPlayPauseClick,
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
                onShare: ShareService.shareSermon,
                onCancelVideoDownload: () => _activeVideoDownload?.cancel(),
                unreadCount: feed.unreadCount,
                onJumpToBottom: _scrollToBottomAndMarkRead,
                viewingImageUrl: _viewingImageUrl,
                onDismissImage: () => setState(() => _viewingImageUrl = null),
              ),
            ),
            // Input bar lives in the body, below the feed, so it moves
            // correctly with the keyboard instead of hiding behind it (see
            // resizeToAvoidBottomInset note above — bottomNavigationBar does
            // not track the keyboard inset). AudioBottomBar wraps its own
            // content in a SafeArea already, so no extra one needed here.
            AudioBottomBar(
              controller: _messageController,
              onSend: _sendTextMessage,
              onUploadClick: () => context.push('/uploadAudio'),
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