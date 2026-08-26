import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';

import '../../cloudinary/cloudinary_upload.dart';
import '../../data/feed_item.dart';
import '../../data/sermon_audio.dart';
import 'reply_target.dart';
import '../audio/global_audio_player.dart';

typedef ReactCallback = void Function(String itemId, String emoji);
typedef DeleteCallback = void Function(String itemId);
typedef SeekCallback = void Function(SermonAudio sermon, double value);
typedef SermonCallback = void Function(SermonAudio sermon);

class AudioFeedList extends StatelessWidget {
  final List<FeedItem> feedItems;
  final ScrollController scrollController;
  final Map<String, Map<String, int>> reactionsMap;
  final String? longPressMenuFor;
  final void Function(String itemId) onLongPress;
  final VoidCallback onDismissLongPressMenu;
  final ReactCallback onReact;
  final void Function(ReplyTarget target) onReply;
  final DeleteCallback onDelete;
  final String? downloadingId;
  final int downloadProgress;
  final String? downloadingVideoId;
  final int videoDownloadProgress;
  final SermonCallback onAudioPlayPauseClick;
  final SeekCallback onSeekChange;
  final SermonCallback onSeekFinished;
  final void Function(String url) onImageClick;
  final SermonCallback onVideoTap;
  final SermonCallback onShare;
  final VoidCallback onCancelVideoDownload;
  final int unreadCount;
  final VoidCallback onJumpToBottom;
  final String? viewingImageUrl;
  final VoidCallback onDismissImage;

  const AudioFeedList({
    super.key,
    required this.feedItems,
    required this.scrollController,
    required this.reactionsMap,
    required this.longPressMenuFor,
    required this.onLongPress,
    required this.onDismissLongPressMenu,
    required this.onReact,
    required this.onReply,
    required this.onDelete,
    required this.downloadingId,
    required this.downloadProgress,
    required this.downloadingVideoId,
    required this.videoDownloadProgress,
    required this.onAudioPlayPauseClick,
    required this.onSeekChange,
    required this.onSeekFinished,
    required this.onImageClick,
    required this.onVideoTap,
    required this.onShare,
    required this.onCancelVideoDownload,
    required this.unreadCount,
    required this.onJumpToBottom,
    required this.viewingImageUrl,
    required this.onDismissImage,
  });

  static const _emojis = ['❤️', '🙏', '😂', '😮', '😢'];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: feedItems.length,
          itemBuilder: (context, index) => _buildItem(context, feedItems[index]),
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

    // No more swipe-to-delete: a swipe deleted the message for every user
    // sharing this feed, since it removed the item straight out of the
    // shared Firebase node. Deletion is now an explicit, confirmed action
    // reached from the long-press menu below, and only hides the message
    // for the user who deleted it (see AudioFeedProvider.deleteItemForMe).
    return GestureDetector(
      key: ValueKey(item.id),
      onLongPress: () => onLongPress(item.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: item.type != 'audio'
                  // Text feed posts never get a share action — audio,
                  // video, and image (all three live under item.type ==
                  // 'audio', distinguished by sermon.mediaType) are the
                  // only content this app treats as shareable.
                  ? _buildTextItem(item)
                  : Stack(
                      children: [
                        switch (item.sermon!.mediaType) {
                          'IMAGE' => _buildImageItem(item.sermon!),
                          'VIDEO' => _buildVideoItem(item.sermon!),
                          _ => _buildAudioItem(item.sermon!),
                        },
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IconButton(
                            icon: const Icon(Icons.share_outlined, size: 18, color: Colors.grey),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Share',
                            onPressed: () => onShare(item.sermon!),
                          ),
                        ),
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
          if (showMenu)
            Wrap(
              spacing: 4,
              children: [
                ..._emojis.map((e) => IconButton(
                  icon: Text(e, style: const TextStyle(fontSize: 20)),
                  onPressed: () => onReact(item.id, e),
                )),
                IconButton(
                  icon: const Icon(Icons.reply),
                  onPressed: () => onReply(ReplyTarget(
                    id: item.id,
                    type: item.type,
                    preview: item.type == 'audio'
                        ? (item.sermon?.title ?? 'Audio')
                        : (item.textMessage?.text ?? ''),
                  )),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _confirmDeleteForMe(context, item.id),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: onDismissLongPressMenu),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteForMe(BuildContext context, String itemId) async {
    onDismissLongPressMenu();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
          "This deletes the message for you only — it will still be visible to everyone else.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (confirmed == true) onDelete(itemId);
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
            child: Text(msg.replyToPreview, style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
          ),
        Text(msg.senderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        const SizedBox(height: 2),
        Text(msg.text),
        const SizedBox(height: 4),
        Text(
          DateFormat.jm().format(DateTime.fromMillisecondsSinceEpoch(msg.timestamp)),
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildAudioItem(SermonAudio sermon) {
    return _AudioItemPlayer(
      sermon: sermon,
      isDownloading: downloadingId == sermon.id,
      downloadProgress: downloadProgress,
      onPlayPauseClick: onAudioPlayPauseClick,
      onSeekChange: onSeekChange,
      onSeekFinished: onSeekFinished,
    );
  }

  Widget _titleAndDescription(SermonAudio sermon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sermon.title.isEmpty ? 'Untitled' : sermon.title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        if (sermon.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(sermon.description, style: const TextStyle(fontSize: 12, color: Colors.black87)),
        ],
      ],
    );
  }

  // WhatsApp-style: the actual photo, not a generic file icon — tap opens
  // the existing full-screen viewer (onImageClick/viewingImageUrl below,
  // which already existed as unused plumbing before this).
  Widget _buildImageItem(SermonAudio sermon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titleAndDescription(sermon),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => onImageClick(sermon.audioUrl),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: CachedNetworkImage(
                imageUrl: sermon.audioUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                placeholder: (context, url) => const SizedBox(
                  height: 180,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (context, url, error) => Container(
                  height: 180,
                  color: Colors.grey.shade200,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // YouTube-style: a real frame from the video as a thumbnail (Cloudinary
  // generates this on the fly from the hosted video URL — see
  // cloudinaryVideoThumbnailUrl — no local video decoding needed), with a
  // play button overlay. Tap reuses the existing download flow — actual
  // in-app playback isn't wired up yet (separate, larger piece of work).
  Widget _buildVideoItem(SermonAudio sermon) {
    final isDownloadingThis = downloadingVideoId == sermon.id;
    final thumbnailUrl = cloudinaryVideoThumbnailUrl(sermon.audioUrl);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titleAndDescription(sermon),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: isDownloadingThis ? null : () => onVideoTap(sermon),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 200,
              width: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                fit: StackFit.expand,
                children: [
                  if (thumbnailUrl != null)
                    CachedNetworkImage(
                      imageUrl: thumbnailUrl,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) =>
                          Container(color: const Color(0xFF102A72)),
                    )
                  else
                    Container(color: const Color(0xFF102A72)),
                  if (isDownloadingThis)
                    Container(
                      color: Colors.black38,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(
                              value: videoDownloadProgress / 100,
                              strokeWidth: 3,
                              color: Colors.white,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('$videoDownloadProgress%',
                              style: const TextStyle(color: Colors.white, fontSize: 11)),
                        ],
                      ),
                    )
                  else
                    Container(
                      decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.play_arrow, color: Colors.white, size: 32),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Reactive audio row — watches GlobalAudioPlayer directly so the play/pause
/// icon and scrub slider update live, matching Kotlin's AudioPlayerRow.
class _AudioItemPlayer extends StatelessWidget {
  final SermonAudio sermon;
  final bool isDownloading;
  final int downloadProgress;
  final SermonCallback onPlayPauseClick;
  final SeekCallback onSeekChange;
  final SermonCallback onSeekFinished;

  const _AudioItemPlayer({
    required this.sermon,
    required this.isDownloading,
    required this.downloadProgress,
    required this.onPlayPauseClick,
    required this.onSeekChange,
    required this.onSeekFinished,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<GlobalAudioPlayer>();
    final isThisTrack = player.nowPlaying?.id == sermon.id;
    final isThisActuallyPlaying = isThisTrack && player.isPlaying;
    final duration = isThisTrack ? player.durationMs : 0;
    final position = isThisTrack
        ? player.positionMs.clamp(0, duration > 0 ? duration : 0)
        : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sermon.title.isEmpty ? 'Untitled' : sermon.title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        if (sermon.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            sermon.description,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ],
        const SizedBox(height: 8),
        if (isDownloading)
          Row(
            children: [
              SizedBox(
                width: 42,
                height: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        value: downloadProgress / 100,
                        strokeWidth: 3,
                        color: const Color(0xFF102A72),
                        backgroundColor: const Color(0xFF102A72).withOpacity(0.15),
                      ),
                    ),
                    Text(
                      '$downloadProgress%',
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF102A72)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Downloading…', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          )
        else
          Row(
            children: [
              SizedBox(
                width: 42,
                height: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        isThisActuallyPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        size: 36,
                        color: const Color(0xFF102A72),
                      ),
                      onPressed: () => onPlayPauseClick(sermon),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
            ],
          ),
      ],
    );
  }
}