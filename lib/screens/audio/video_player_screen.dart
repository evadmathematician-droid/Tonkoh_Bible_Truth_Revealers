import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../data/sermon_audio.dart';
import '../../services/share_service.dart';

/// Full-screen video playback. [source] is either a local file path
/// (native, post-download) or a network URL (web — no local file caching
/// there, since path_provider has no web implementation).
class VideoPlayerScreen extends StatefulWidget {
  final String source;
  final bool isFile;
  final String title;
  /// Optional — when present, shows a share action in the AppBar (needs
  /// the original sermon record, not just the resolved local/network
  /// [source], to build the branded preview via ShareService).
  final SermonAudio? sermon;

  const VideoPlayerScreen({
    super.key,
    required this.source,
    required this.title,
    this.isFile = false,
    this.sermon,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = widget.isFile
        ? VideoPlayerController.file(File(widget.source))
        : VideoPlayerController.networkUrl(Uri.parse(widget.source));
    _controller
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();
      }).catchError((Object e) {
        if (!mounted) return;
        setState(() => _error = e.toString());
      })
      ..addListener(() {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title.isEmpty ? 'Video' : widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.sermon != null)
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: 'Share',
              onPressed: () => ShareService.shareSermon(widget.sermon!),
            ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Couldn't play this video: $_error",
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              )
            : !_ready
                ? const CircularProgressIndicator(color: Colors.white)
                : GestureDetector(
                    onTap: _togglePlay,
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio == 0 ? 16 / 9 : _controller.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(_controller),
                          if (!_controller.value.isPlaying)
                            Container(
                              decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                              padding: const EdgeInsets.all(16),
                              child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: VideoProgressIndicator(
                              _controller,
                              allowScrubbing: true,
                              padding: const EdgeInsets.all(8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
      ),
    );
  }
}
