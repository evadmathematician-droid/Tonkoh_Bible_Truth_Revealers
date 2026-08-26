import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/private_message.dart';

const _kBrand = Color(0xFF102A72);

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

  @override
  Widget build(BuildContext context) {
    ImageProvider? image;
    if (photoBase64.isNotEmpty) {
      try {
        image = MemoryImage(base64Decode(photoBase64));
      } catch (_) {
        image = null;
      }
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: _kBrand.withOpacity(0.15),
      backgroundImage: image,
      child: image == null
          ? Text(
        displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
        style: TextStyle(fontSize: size * 0.4, color: _kBrand, fontWeight: FontWeight.bold),
      )
          : null,
    );
  }
}

class ReadReceiptTick extends StatelessWidget {
  final bool isRead;
  final EdgeInsetsGeometry? modifier;

  const ReadReceiptTick({super.key, required this.isRead, this.modifier});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: modifier ?? EdgeInsets.zero,
      child: Icon(
        isRead ? Icons.done_all : Icons.done,
        size: 14,
        color: isRead ? const Color(0xFF1565C0) : Colors.grey,
      ),
    );
  }
}

class ReplyQuotePreview extends StatelessWidget {
  final PrivateMessage message;
  final bool isMine;

  const ReplyQuotePreview({super.key, required this.message, this.isMine = false});

  @override
  Widget build(BuildContext context) {
    if (message.replyToId.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isMine ? Colors.white.withOpacity(0.15) : _kBrand.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: isMine ? Colors.white : _kBrand, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.replyToSenderName.isEmpty ? 'Reply' : message.replyToSenderName,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isMine ? Colors.white : _kBrand,
            ),
          ),
          Text(
            message.replyToText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: isMine ? Colors.white.withOpacity(0.85) : Colors.black54,
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
  final String fileUrl; // base64
  const ImageMessageBubble({super.key, required this.fileUrl});

  @override
  Widget build(BuildContext context) {
    if (fileUrl.isEmpty) return const SizedBox.shrink();

    Uint8List? bytes;
    try {
      bytes = base64Decode(fileUrl);
    } catch (_) {
      bytes = null;
    }

    if (bytes == null) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Could not load photo', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    final imageBytes = bytes;

    return GestureDetector(
      onTap: () => _openFullScreen(context, imageBytes),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 230, maxHeight: 300, minWidth: 120, minHeight: 120),
          child: Image.memory(
            imageBytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              width: 200,
              height: 160,
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  void _openFullScreen(BuildContext context, Uint8List bytes) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (context, _, __) => _FullScreenImageViewer(bytes: bytes),
      ),
    );
  }
}

class _FullScreenImageViewer extends StatelessWidget {
  final Uint8List bytes;
  const _FullScreenImageViewer({required this.bytes});

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
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// Video playback is deferred here — same as the Kotlin version, which
/// only handles the download/cache step and leaves actual playback for
/// a later pass. Tapping shows a "not yet wired up" message.
class VideoMessageBubble extends StatelessWidget {
  final String fileUrl;
  final String mimeType;
  final bool isMine;

  const VideoMessageBubble({
    super.key,
    required this.fileUrl,
    required this.mimeType,
    required this.isMine,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Video playback isn't wired up yet.")),
        );
      },
      child: Container(
        height: 160,
        width: double.infinity,
        decoration: BoxDecoration(
          color: _kBrand,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam, color: Colors.white, size: 32),
            SizedBox(height: 6),
            Text('Video', style: TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class AudioAttachmentBubble extends StatelessWidget {
  final String fileUrl;
  final String fileName;
  final bool isMine;

  const AudioAttachmentBubble({
    super.key,
    required this.fileUrl,
    required this.fileName,
    required this.isMine,
  });

  @override
  Widget build(BuildContext context) {
    final color = isMine ? Colors.white : _kBrand;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.music_note, color: color, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            fileName.isEmpty ? 'Audio' : fileName,
            style: TextStyle(color: color, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
      final bytes = base64Decode(fileUrl);
      final name = fileName.isEmpty ? 'attachment' : fileName;
      final xfile = XFile.fromData(bytes, name: name, mimeType: mimeType.isEmpty ? null : mimeType);
      await Share.shareXFiles([xfile]);
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
    final color = isMine ? Colors.white : _kBrand;
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
      setState(() => _isPlaying = state.playing && state.processingState != ProcessingState.completed);
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
    final color = widget.isMine ? Colors.white : _kBrand;
    final total = _totalDuration ?? Duration(seconds: widget.duration);
    final progress = total.inMilliseconds == 0 ? 0.0 : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
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
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
          )
              : IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: color, size: 30),
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
                    backgroundColor: color.withOpacity(0.25),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                const SizedBox(height: 2),
                Text('${remaining}s', style: TextStyle(color: color, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}