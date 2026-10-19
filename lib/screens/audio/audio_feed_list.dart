import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../cloudinary/cloudinary_upload.dart';
import '../../data/display_names.dart';
import '../../data/phone_aliases.dart';
import '../../data/feed_item.dart';
import '../../data/sermon_audio.dart';
import '../../links/link_preview_card.dart';
import '../../services/share_service.dart';
import '../../util/chat_time.dart';
import '../../widgets/media_download_button.dart';
import '../components/profile_avatar.dart';
import 'reply_target.dart';
import '../audio/global_audio_player.dart';

typedef ReactCallback = void Function(String itemId, String emoji);
typedef DeleteCallback = void Function(String itemId, String itemType);
typedef SeekCallback = void Function(SermonAudio sermon, double value);
typedef SermonCallback = void Function(SermonAudio sermon);

class AudioFeedList extends StatelessWidget {
  /// Oldest first. Drawn reversed: index 0 of the list is the newest post,
  /// at the bottom, so the screen can open "at the newest" or exactly at a
  /// saved post ([initialScrollIndex] / [initialAlignment], reversed
  /// indices) with no visible jump.
  final List<FeedItem> feedItems;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final int initialScrollIndex;
  final double initialAlignment;

  /// "N new messages" divider goes above this post (null: no divider).
  final String? unreadDividerId;
  final int unreadDividerCount;
  final Map<String, Map<String, int>> reactionsMap;
  final String? longPressMenuFor;
  final void Function(String itemId) onLongPress;
  final VoidCallback onDismissLongPressMenu;
  final ReactCallback onReact;
  final void Function(ReplyTarget target) onReply;
  final DeleteCallback onDelete;
  final SermonCallback onAudioPlayPauseClick;
  final SermonCallback onShareAudio;
  final SermonCallback onShareVideo;
  final SeekCallback onSeekChange;
  final SermonCallback onSeekFinished;
  final void Function(String url) onImageClick;
  final SermonCallback onVideoTap;
  final int unreadCount;
  final VoidCallback onJumpToBottom;
  final String? viewingImageUrl;
  final VoidCallback onDismissImage;

  /// This user's id, so their own posts read "You" and aren't tappable.
  final String? currentUid;

  /// Tapped a member's photo or name: [senderId] is their account id and
  /// [replyTarget] the post it was tapped on (for the sheet's "Reply").
  final void Function(String senderId, ReplyTarget replyTarget)? onSenderTap;

  const AudioFeedList({
    super.key,
    required this.feedItems,
    required this.itemScrollController,
    required this.itemPositionsListener,
    this.initialScrollIndex = 0,
    this.initialAlignment = 0,
    this.unreadDividerId,
    this.unreadDividerCount = 0,
    required this.reactionsMap,
    required this.longPressMenuFor,
    required this.onLongPress,
    required this.onDismissLongPressMenu,
    required this.onReact,
    required this.onReply,
    required this.onDelete,
    required this.onAudioPlayPauseClick,
    required this.onShareAudio,
    required this.onShareVideo,
    required this.onSeekChange,
    required this.onSeekFinished,
    required this.onImageClick,
    required this.onVideoTap,
    required this.unreadCount,
    required this.onJumpToBottom,
    required this.viewingImageUrl,
    required this.onDismissImage,
    this.currentUid,
    this.onSenderTap,
  });

  static const _emojis = ['❤️', '🙏', '😂', '😮', '😢'];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ScrollablePositionedList.builder(
          itemScrollController: itemScrollController,
          itemPositionsListener: itemPositionsListener,
          reverse: true,
          initialScrollIndex: feedItems.isEmpty
              ? 0
              : initialScrollIndex.clamp(0, feedItems.length - 1),
          initialAlignment: initialAlignment,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: feedItems.length,
          itemBuilder: (context, displayIndex) {
            final index = feedItems.length - 1 - displayIndex;
            final item = feedItems[index];
            final showDivider = index == 0 ||
                !isSameDay(
                  DateTime.fromMillisecondsSinceEpoch(
                      feedItems[index - 1].timestamp),
                  DateTime.fromMillisecondsSinceEpoch(item.timestamp),
                );
            final showUnread = item.id == unreadDividerId;
            final row = _buildItem(context, item);
            if (!showDivider && !showUnread) return row;
            return Column(
              children: [
                if (showDivider)
                  _FeedDateDivider(label: dateDividerLabel(item.timestamp)),
                if (showUnread) _UnreadDivider(count: unreadDividerCount),
                row,
              ],
            );
          },
        ),
        if (unreadCount > 0)
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.small(
              onPressed: onJumpToBottom,
              backgroundColor: const Color(0xFF102A72),
              child: Badge(
                label: Text('$unreadCount'),
                child: const Icon(Icons.arrow_downward, color: Colors.white),
              ),
            ),
          ),
        if (viewingImageUrl != null)
          GestureDetector(
            onTap: onDismissImage,
            child: Container(
              color: Colors.black87,
              alignment: Alignment.center,
              child: InteractiveViewer(
                child: CachedNetworkImage(imageUrl: viewingImageUrl!),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, FeedItem item) {
    final reactions = reactionsMap[item.id] ?? const {};
    final showMenu = longPressMenuFor == item.id;

    return GestureDetector(
      onLongPress: () => onLongPress(item.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _senderHeader(context, item),
                  const SizedBox(height: 6),
                  item.type == 'audio'
                      ? _buildMediaItem(item.sermon!)
                      : _buildTextItem(item),
                ],
              ),
            ),
          ),
          if (reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 4),
              child: Wrap(
                spacing: 6,
                children: reactions.entries
                    .where((e) => e.value > 0)
                    .map((e) => Chip(
                          label: Text('${e.key} ${e.value}'),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ),
          if (showMenu) _itemMenu(context, item),
        ],
      ),
    );
  }

  ReplyTarget _replyTargetFor(FeedItem item) => ReplyTarget(
        id: item.id,
        type: item.type,
        preview: item.type != 'audio'
            ? (item.textMessage?.text ?? '')
            : (item.sermon?.title ?? 'Audio'),
      );

  /// Photo + name of whoever posted [item]. Name follows the contact rule
  /// (saved name, else the number). Tapping it opens the private
  /// message / call / reply sheet — except on my own posts.
  Widget _senderHeader(BuildContext context, FeedItem item) {
    // Old posts can carry a malformed id ("+031932652") — resolve it so
    // the name, photo and private-chat link reach the right account.
    final senderId = resolveUserId(
        item.sermon?.senderId ?? item.textMessage?.senderId ?? '');
    final isMine = senderId.isNotEmpty && senderId == currentUid;
    final name = isMine
        ? 'You'
        : senderId.isEmpty
            ? 'Member'
            : context.watch<DisplayNames>().nameFor(senderId);
    final tap = (isMine || senderId.isEmpty || onSenderTap == null)
        ? null
        : () => onSenderTap!(senderId, _replyTargetFor(item));

    return InkWell(
      onTap: tap,
      borderRadius: BorderRadius.circular(20),
      child: Row(
        children: [
          CachedProfileAvatar(
            uid: senderId,
            name: isMine ? (item.textMessage?.senderName ?? 'You') : name,
            size: 32,
            onTap: tap,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Color(0xFF102A72),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemMenu(BuildContext context, FeedItem item) {
    final isText = item.type != 'audio';
    return Container(
      margin: const EdgeInsets.only(left: 4, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ..._emojis.map((e) => InkWell(
                onTap: () => onReact(item.id, e),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(e, style: const TextStyle(fontSize: 18)),
                ),
              )),
          const SizedBox(width: 2),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.reply, size: 20),
            tooltip: 'Reply',
            onPressed: () => onReply(_replyTargetFor(item)),
          ),
          if (isText)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 20),
              tooltip: 'Copy',
              onPressed: () async {
                await Clipboard.setData(
                    ClipboardData(text: item.textMessage?.text ?? ''));
                onDismissLongPressMenu();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Copied'),
                        duration: Duration(seconds: 1)),
                  );
                }
              },
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.share, size: 20),
            tooltip: 'Share',
            onPressed: () {
              onDismissLongPressMenu();
              final sermon = item.sermon;
              if (sermon == null) {
                ShareService.instance.shareText(item.textMessage?.text ?? '');
              } else if (sermon.mediaType.toUpperCase() == 'VIDEO') {
                onShareVideo(sermon);
              } else {
                onShareAudio(sermon);
              }
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Delete for me',
            onPressed: () {
              onDelete(item.id, item.type);
              onDismissLongPressMenu();
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 20),
            onPressed: onDismissLongPressMenu,
          ),
        ],
      ),
    );
  }

  Widget _buildTextItem(FeedItem item) {
    final msg = item.textMessage!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (msg.replyToPreview.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(6),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(msg.replyToPreview,
                style:
                    const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
          ),
        Text(msg.text),
        if (msg.link != null) ...[
          const SizedBox(height: 8),
          LinkPreviewCard(preview: msg.link!),
        ],
        const SizedBox(height: 4),
        Text(
          messageClock(msg.timestamp),
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }

  /// A feed item with `type == 'audio'` is really "a sermon media post" —
  /// it can be an audio track, an image, or a video (see `mediaType`, set
  /// from `MediaKind` in upload_sheet.dart). Previously every one of these
  /// rendered as an audio player row with a play button and scrub slider,
  /// so images and videos showed up looking like broken audio. Branch on
  /// `mediaType` so each kind gets its own presentation.
  Widget _buildMediaItem(SermonAudio sermon) {
    if (sermon.isLink) return _LinkPost(sermon: sermon);
    switch (sermon.mediaType.toUpperCase()) {
      case 'IMAGE':
        return _ImageItem(
          sermon: sermon,
          onTap: () => onImageClick(sermon.audioUrl),
        );
      case 'VIDEO':
        return _VideoItem(
          sermon: sermon,
          onTap: () => onVideoTap(sermon),
          onShare: () => onShareVideo(sermon),
        );
      case 'AUDIO':
      default:
        return _AudioItemPlayer(
          sermon: sermon,
          onPlayPauseClick: onAudioPlayPauseClick,
          onShare: onShareAudio,
          onSeekChange: onSeekChange,
          onSeekFinished: onSeekFinished,
        );
    }
  }
}

/// Title shown under a thumbnail (the sender is in the card's header).
Widget _mediaCaption(SermonAudio sermon) {
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(sermon.title.isEmpty ? 'Untitled' : sermon.title,
        style: const TextStyle(fontWeight: FontWeight.bold)),
  );
}

Widget _thumbLoading() => const ColoredBox(
      color: Color(0xFFECEFF3),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );

Widget _thumbBroken(IconData icon) => ColoredBox(
      color: const Color(0xFFECEFF3),
      child: Center(child: Icon(icon, color: Colors.grey, size: 32)),
    );

/// Inline image post — a real thumbnail (not a placeholder tile); tapping
/// opens the existing full-screen viewer via [onTap].
class _ImageItem extends StatelessWidget {
  final SermonAudio sermon;
  final VoidCallback onTap;

  const _ImageItem({required this.sermon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: CachedNetworkImage(
                imageUrl: sermon.audioUrl,
                fit: BoxFit.cover,
                // The tile is at most screen-wide; don't hold the original
                // upload's full resolution in memory for every feed row.
                // Tapping still opens the full-size image.
                memCacheWidth: (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
                placeholder: (_, __) => _thumbLoading(),
                errorWidget: (_, __, ___) =>
                    _thumbBroken(Icons.broken_image_outlined),
              ),
            ),
          ),
          _mediaCaption(sermon),
        ],
      ),
    );
  }
}

/// Video post — a poster-frame thumbnail (from Cloudinary) with a play
/// badge. Tapping opens the WhatsApp-style player, which streams the
/// video immediately and saves a resumable offline copy. If a save for
/// this sermon is already in progress, the tile shows a small ring.
class _VideoItem extends StatelessWidget {
  final SermonAudio sermon;
  final VoidCallback onTap;
  final VoidCallback onShare;

  const _VideoItem({
    required this.sermon,
    required this.onTap,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: cloudinaryVideoThumbnail(sermon.audioUrl),
                  fit: BoxFit.cover,
                  placeholder: (_, __) => _thumbLoading(),
                  errorWidget: (_, __, ___) =>
                      _thumbBroken(Icons.movie_outlined),
                ),
                Container(color: Colors.black26),
                // Center: play only.
                Center(
                  child: GestureDetector(
                    onTap: onTap,
                    child: const Icon(Icons.play_circle_fill,
                        size: 52, color: Colors.white),
                  ),
                ),
                // Bottom-left: dedicated download control.
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: MediaDownloadButton(
                    cacheKey: sermon.id,
                    url: sermon.audioUrl,
                    ext: '.mp4',
                    size: 38,
                  ),
                ),
                // Bottom-right: share.
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: GestureDetector(
                    onTap: onShare,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                          color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.share,
                          color: Colors.white, size: 19),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _mediaCaption(sermon),
      ],
    );
  }
}

/// Sticky-style day separator between feed items ("Today", "Yesterday",
/// a weekday, or a date).
class _FeedDateDivider extends StatelessWidget {
  final String label;
  const _FeedDateDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white70,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF102A72),
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Reactive audio row — watches GlobalAudioPlayer directly so the play/pause
/// icon and scrub slider update live, matching Kotlin's AudioPlayerRow.
class _AudioItemPlayer extends StatelessWidget {
  final SermonAudio sermon;
  final SermonCallback onPlayPauseClick;
  final SermonCallback onShare;
  final SeekCallback onSeekChange;
  final SermonCallback onSeekFinished;

  const _AudioItemPlayer({
    required this.sermon,
    required this.onPlayPauseClick,
    required this.onShare,
    required this.onSeekChange,
    required this.onSeekFinished,
  });

  @override
  Widget build(BuildContext context) {
    // Selector, not context.watch: GlobalAudioPlayer notifies on every
    // position tick (~5-10×/s while playing). A bare watch would rebuild
    // EVERY visible audio row — and its Slider — on each tick, janking the
    // list and making taps on other rows' share/play icons feel sluggish or
    // get dropped. The selected record is constant for any row that isn't
    // the current track, so those rows never rebuild during playback.
    return Selector<GlobalAudioPlayer,
        ({bool isThisTrack, bool playing, bool buffering, int pos, int dur})>(
      selector: (_, p) {
        final mine = p.nowPlaying?.id == sermon.id;
        return (
          isThisTrack: mine,
          playing: mine && p.isPlaying,
          buffering: mine && p.isBuffering,
          pos: mine ? p.positionMs : 0,
          dur: mine ? p.durationMs : 0,
        );
      },
      builder: (context, s, _) {
        final isThisActuallyPlaying = s.playing;
        final isThisBuffering = s.buffering;
        final duration = s.dur;
        final position = s.pos.clamp(0, duration > 0 ? duration : 0);
        return _buildRow(
          context,
          isThisActuallyPlaying: isThisActuallyPlaying,
          isThisBuffering: isThisBuffering,
          duration: duration,
          position: position,
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required bool isThisActuallyPlaying,
    required bool isThisBuffering,
    required int duration,
    required int position,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sermon.title.isEmpty ? 'Untitled' : sermon.title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [
            isThisBuffering
                ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Color(0xFF102A72)),
                    ),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      isThisActuallyPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      size: 36,
                      color: const Color(0xFF102A72),
                    ),
                    onPressed: () => onPlayPauseClick(sermon),
                  ),
            const SizedBox(width: 6),
            Expanded(
              child: Slider(
                value: duration > 0
                    ? position.toDouble().clamp(0, duration.toDouble())
                    : 0,
                max: duration > 0 ? duration.toDouble() : 1,
                onChanged: (v) => onSeekChange(sermon, v),
                onChangeEnd: (_) => onSeekFinished(sermon),
              ),
            ),
            // Dedicated circular download control.
            MediaDownloadButton(
              cacheKey: sermon.id,
              url: sermon.audioUrl,
              ext: '.mp3',
              size: 32,
              color: const Color(0xFF102A72),
              background: const Color(0x14102A72),
              onStopPlayback: () {
                final p = context.read<GlobalAudioPlayer>();
                if (p.nowPlaying?.id == sermon.id) p.pause();
              },
            ),
            const SizedBox(width: 2),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.share,
                  size: 20, color: Color(0xFF102A72)),
              tooltip: 'Share',
              onPressed: () => onShare(sermon),
            ),
          ],
        ),
        // The uploader's full description, shown only for audio items, on a
        // black card with white text.
        if (sermon.description.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              sermon.description.trim(),
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ],
    );
  }
}


/// "3 new messages" — above the first post that arrived since the last
/// visit (WhatsApp style).
class _UnreadDivider extends StatelessWidget {
  final int count;
  const _UnreadDivider({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('feedUnreadDivider'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 5),
      color: const Color(0xCCFFFFFF),
      alignment: Alignment.center,
      child: Text(
        count == 1 ? '1 new message' : '$count new messages',
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF102A72)),
      ),
    );
  }
}

/// A YouTube / TikTok / web link shared into the Audio screen (approved
/// like any upload): the sharer's caption, then the rich preview card.
class _LinkPost extends StatelessWidget {
  final SermonAudio sermon;
  const _LinkPost({required this.sermon});

  @override
  Widget build(BuildContext context) {
    final link = sermon.link!;
    final caption = sermon.description.trim().isNotEmpty
        ? sermon.description.trim()
        : link.sharedText.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (caption.isNotEmpty && caption != link.url) ...[
          Text(caption),
          const SizedBox(height: 8),
        ],
        LinkPreviewCard(preview: link),
        const SizedBox(height: 4),
        Text(
          messageClock(sermon.timestamp),
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }
}
