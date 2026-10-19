import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../cloudinary/cloudinary_upload.dart';
import '../../data/private_message.dart';
import '../../util/base64_image_cache.dart';
import '../../services/share_service.dart';
import '../../ui/chat_theme.dart';
import '../../widgets/media_download_button.dart';
import '../components/profile_avatar.dart' show avatarInitials;
import '../media/cached_audio_tile.dart';
import '../media/network_video_screen.dart';

const _kBrand = Color(0xFF102A72);

/// Chat media sources are now Cloudinary URLs; older messages still carry
/// raw base64. One helper so every bubble branches the same way.
bool isRemoteMediaSource(String s) =>
    s.startsWith('http://') || s.startsWith('https://');

class AvatarView extends StatelessWidget {
  final String photoBase64;
  final String displayName;
  final double size;

  const AvatarView({
    super.key,
    required this.photoBase64,
    required this.displayName,
    this.size = 28,
  });

  // Initials when the name has letters, otherwise a person icon — an
  // unsaved contact's name is their number, and "+" is not an initial.
  Widget _fallback() {
    final initials = avatarInitials(displayName, max: 1);
    if (initials.isEmpty) {
      return Icon(Icons.person, size: size * 0.6, color: _kBrand);
    }
    return Text(
      initials,
      style: TextStyle(
          fontSize: size * 0.4, color: _kBrand, fontWeight: FontWeight.bold),
    );
  }

  @override
  Widget build(BuildContext context) {
    ImageProvider? image;
    final bytes = Base64ImageCache.decode(photoBase64);
    if (bytes != null) {
      // Decode the avatar at its display size, not the full crop
      // resolution — see ProfileAvatar for the same reasoning.
      final px = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
      image = ResizeImage(MemoryImage(bytes), width: px, height: px);
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: _kBrand.withValues(alpha: 0.15),
      backgroundImage: image,
      child: image == null ? _fallback() : null,
    );
  }
}

/// WhatsApp-style tick for one of my messages: clock while it waits on
/// this phone (offline / sending), one tick on the server, two grey ticks
/// once the other phone has it, two blue ticks once it has been read.
class MessageStatusTick extends StatelessWidget {
  final int status;
  final bool isRead;
  final Color color;
  final Color readColor;

  const MessageStatusTick({
    super.key,
    required this.status,
    required this.isRead,
    this.color = Colors.grey,
    this.readColor = const Color(0xFF1565C0),
  });

  @override
  Widget build(BuildContext context) {
    final (icon, c, label) = switch (status) {
      MessageStatus.pending => (Icons.schedule, color, 'Sending'),
      _ when isRead => (Icons.done_all, readColor, 'Read'),
      MessageStatus.delivered => (Icons.done_all, color, 'Delivered'),
      _ => (Icons.done, color, 'Sent'),
    };
    return Icon(icon, size: 14, color: c, semanticLabel: label);
  }
}

class ReplyQuotePreview extends StatelessWidget {
  final PrivateMessage message;
  final bool isMine;

  /// Display name for the quoted sender (saved contact / number / "You");
  /// falls back to the name stored on the message.
  final String? senderLabel;

  const ReplyQuotePreview(
      {super.key, required this.message, this.isMine = false, this.senderLabel});

  @override
  Widget build(BuildContext context) {
    if (message.replyToId.isEmpty) return const SizedBox.shrink();
    final palette = ChatTheme.of(context);
    final accent = palette.accent(isMine);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isMine ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (senderLabel ?? message.replyToSenderName).isEmpty
                ? 'Reply'
                : (senderLabel ?? message.replyToSenderName),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: accent,
            ),
          ),
          Text(
            message.replyToText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: palette.secondary(isMine),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chat-style image bubble: bounded thumbnail (no more full-bleed
/// stretch/crop of odd-aspect-ratio photos), loading/error states, and
/// tap-to-preview full screen with pinch-to-zoom.
class ImageMessageBubble extends StatelessWidget {
  final String fileUrl; // Cloudinary URL or legacy base64
  const ImageMessageBubble({super.key, required this.fileUrl});

  @override
  Widget build(BuildContext context) {
    if (fileUrl.isEmpty) return const SizedBox.shrink();

    const constraints = BoxConstraints(
        maxWidth: 230, maxHeight: 300, minWidth: 120, minHeight: 120);
    // Decode at most as wide as the bubble can draw; the full-screen viewer
    // still loads the original. Aspect ratio is kept and small photos are
    // never upscaled, so the bubble's size is unchanged.
    final decodeWidth =
        (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context)).ceil();

    if (isRemoteMediaSource(fileUrl)) {
      return GestureDetector(
        onTap: () => _open(context, _FullScreenImageViewer.network(fileUrl)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: constraints,
            child: CachedNetworkImage(
              imageUrl: fileUrl,
              fit: BoxFit.cover,
              memCacheWidth: decodeWidth,
              placeholder: (_, __) => Container(
                width: 200,
                height: 160,
                color: Colors.grey.shade200,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
              errorWidget: (_, __, ___) => _brokenImage(),
            ),
          ),
        ),
      );
    }

    final bytes = Base64ImageCache.decode(fileUrl);
    if (bytes == null) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Could not load photo',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    final imageBytes = bytes;
    return GestureDetector(
      onTap: () => _open(context, _FullScreenImageViewer.bytes(imageBytes)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: constraints,
          child: Image.memory(
            imageBytes,
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            errorBuilder: (_, __, ___) => _brokenImage(),
          ),
        ),
      ),
    );
  }

  static Widget _brokenImage() => Container(
        width: 200,
        height: 160,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image, color: Colors.grey),
      );

  void _open(BuildContext context, Widget viewer) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) => viewer,
      ),
    );
  }
}

class _FullScreenImageViewer extends StatelessWidget {
  final Uint8List? bytes;
  final String? url;
  const _FullScreenImageViewer.bytes(this.bytes) : url = null;
  const _FullScreenImageViewer.network(this.url) : bytes = null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: bytes != null
              ? Image.memory(bytes!, fit: BoxFit.contain)
              : CachedNetworkImage(imageUrl: url!, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// Chat video bubble: poster thumbnail with a play badge and, for remote
/// videos, a live download-progress ring. Tapping opens the WhatsApp-style
/// player (stream now, resumable save in the background).
class VideoMessageBubble extends StatelessWidget {
  final String messageId;
  final String fileUrl;
  final String mimeType;
  final bool isMine;

  const VideoMessageBubble({
    super.key,
    required this.messageId,
    required this.fileUrl,
    required this.mimeType,
    required this.isMine,
  });

  @override
  Widget build(BuildContext context) {
    final remote = isRemoteMediaSource(fileUrl);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: 170,
        width: 240,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (remote)
              CachedNetworkImage(
                imageUrl: cloudinaryVideoThumbnail(fileUrl),
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: _kBrand),
                errorWidget: (_, __, ___) => Container(color: _kBrand),
              )
            else
              Container(color: _kBrand),
            Container(color: Colors.black26),
            // Center: play only.
            Center(
              child: GestureDetector(
                onTap: () =>
                    remote ? _openRemote(context) : _openLegacy(context),
                child: const Icon(Icons.play_circle_fill,
                    size: 52, color: Colors.white),
              ),
            ),
            // Bottom-left: dedicated download control (remote videos only).
            if (remote)
              Positioned(
                left: 8,
                bottom: 8,
                child: MediaDownloadButton(
                  cacheKey: messageId,
                  url: fileUrl,
                  ext: '.mp4',
                  size: 38,
                ),
              ),
            // Bottom-right: share.
            Positioned(
              right: 8,
              bottom: 8,
              child: _ShareIconButton(
                onTap: () => ShareService.instance.shareVideo(
                  title: '',
                  cacheKey: remote ? messageId : null,
                  remoteUrl: remote ? fileUrl : null,
                  thumbnailUrl:
                      remote ? cloudinaryVideoThumbnail(fileUrl) : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openRemote(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NetworkVideoScreen(
        url: fileUrl,
        cacheKey: messageId,
        title: 'Video',
      ),
    ));
  }

  Future<void> _openLegacy(BuildContext context) async {
    try {
      final bytes = base64Decode(fileUrl);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/legacy_$messageId.mp4');
      if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NetworkVideoScreen(
          url: '',
          cacheKey: messageId,
          title: 'Video',
          filePath: file.path,
        ),
      ));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't play this video.")),
        );
      }
    }
  }
}

/// Small circular share button used in the corner of media bubbles.
class _ShareIconButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ShareIconButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration:
            const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: const Icon(Icons.share, color: Colors.white, size: 19),
      ),
    );
  }
}

class AudioAttachmentBubble extends StatelessWidget {
  final String messageId;
  final String fileUrl;
  final String fileName;
  final String mimeType;
  final bool isMine;
  final int durationSeconds;

  const AudioAttachmentBubble({
    super.key,
    required this.messageId,
    required this.fileUrl,
    required this.fileName,
    required this.isMine,
    this.mimeType = '',
    this.durationSeconds = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (fileUrl.isEmpty) return const SizedBox.shrink();
    return CachedAudioTile(
      messageId: messageId,
      source: fileUrl,
      fileName: fileName,
      mimeType: mimeType,
      isMine: isMine,
      durationSeconds: durationSeconds,
    );
  }
}

/// Uses share_plus (already a dependency) instead of path_provider +
/// dart:io File — that combination has no web implementation and was
/// throwing MissingPluginException on Chrome, same failure mode as the
/// SQLite issue. share_plus works uniformly across web/mobile/desktop:
/// on web it triggers a browser download / native share sheet, on
/// mobile/desktop it opens the OS share sheet.
class FileMessageBubble extends StatelessWidget {
  final String fileUrl;
  final String fileName;
  final String mimeType;
  final bool isMine;

  const FileMessageBubble({
    super.key,
    required this.fileUrl,
    required this.fileName,
    required this.mimeType,
    required this.isMine,
  });

  Future<void> _openFile(BuildContext context) async {
    try {
      if (isRemoteMediaSource(fileUrl)) {
        await SharePlus.instance.share(ShareParams(text: fileUrl, subject: fileName));
        return;
      }
      final bytes = base64Decode(fileUrl);
      final name = fileName.isEmpty ? 'attachment' : fileName;
      final xfile = XFile.fromData(bytes,
          name: name, mimeType: mimeType.isEmpty ? null : mimeType);
      await SharePlus.instance.share(ShareParams(files: [xfile]));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open that file.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = ChatTheme.of(context).accent(isMine);
    return InkWell(
      onTap: () => _openFile(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, color: color, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              fileName.isEmpty ? 'File' : fileName,
              style: TextStyle(color: color, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal sticker rendering placeholder until Stickers.dart (the port
/// of your Stickers.kt) is wired in — renders the sticker id as an emoji
/// tile so the layout doesn't break.
class StickerMessageBubble extends StatelessWidget {
  final String stickerId;
  const StickerMessageBubble({super.key, required this.stickerId});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 84,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(stickerId, style: const TextStyle(fontSize: 32)),
    );
  }
}

/// Real voice playback via just_audio, fed a base64 data: URI directly —
/// no temp files, no path_provider, works the same on web/mobile/desktop.
/// Matches the filesystem-free approach used in voice_recorder.dart.
class VoiceMessageBubble extends StatefulWidget {
  final String audioUrl; // base64
  final int duration; // seconds
  final bool isMine;

  const VoiceMessageBubble({
    super.key,
    required this.audioUrl,
    required this.duration,
    required this.isMine,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  AudioPlayer? _player;
  bool _isLoading = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _totalDuration;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _ensurePlayerReady() async {
    if (_player != null) return;

    final player = AudioPlayer();
    _player = player;

    player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _isPlaying =
          state.playing && state.processingState != ProcessingState.completed);
      if (state.processingState == ProcessingState.completed) {
        player.seek(Duration.zero);
        player.pause();
        setState(() => _position = Duration.zero);
      }
    });
    player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });

    // Guess a reasonable mime type — recordings from voice_recorder.dart
    // are WAV; attachments picked as audio/* keep their original type.
    final mimeType = widget.audioUrl.isNotEmpty ? 'audio/wav' : 'audio/mpeg';
    final dataUri = 'data:$mimeType;base64,${widget.audioUrl}';

    try {
      _totalDuration = await player.setUrl(dataUri);
    } catch (_) {
      _totalDuration = Duration(seconds: widget.duration);
    }
  }

  Future<void> _togglePlay() async {
    if (widget.audioUrl.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      await _ensurePlayerReady();
      final player = _player!;
      if (player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't play voice message.")),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = ChatTheme.of(context).accent(widget.isMine);
    final total = _totalDuration ?? Duration(seconds: widget.duration);
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final remaining = _isPlaying || _position > Duration.zero
        ? (total - _position).inSeconds.clamp(0, 1 << 30)
        : widget.duration;

    return SizedBox(
      width: 170,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _isLoading
              ? SizedBox(
                  width: 30,
                  height: 30,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: color),
                  ),
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(
                      _isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      color: color,
                      size: 30),
                  onPressed: _togglePlay,
                ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: color.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                const SizedBox(height: 2),
                Text('${remaining}s',
                    style: TextStyle(color: color, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
