import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/resumable_downloader.dart';

/// Full-screen video player that behaves like WhatsApp:
///  * Playback starts immediately by streaming [url] progressively — you
///    watch the part that has arrived while the rest keeps coming.
///  * In parallel a resumable download saves a permanent local copy. If
///    the connection drops or data runs out, the save resumes from the
///    byte it stopped at (see [ResumableDownloader]).
///  * Once the local copy is complete, playback switches to the file so
///    re-opening the video costs no data.
class NetworkVideoScreen extends StatefulWidget {
  final String url;

  /// Stable cache key — the chat message id or the sermon id.
  final String cacheKey;
  final String title;

  /// When set, playback comes straight from this local file and no
  /// download runs (used for legacy base64 chat videos decoded to a
  /// temp file).
  final String? filePath;

  const NetworkVideoScreen({
    super.key,
    required this.url,
    required this.cacheKey,
    this.title = '',
    this.filePath,
  });

  @override
  State<NetworkVideoScreen> createState() => _NetworkVideoScreenState();
}

class _NetworkVideoScreenState extends State<NetworkVideoScreen> {
  static const _ext = '.mp4';

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _switchedToFile = false;
  String? _error;

  ResumableDownloader get _dl => ResumableDownloader.instance;

  @override
  void initState() {
    super.initState();
    _boot();
    _dl.watch(widget.cacheKey).addListener(_onDownload);
  }

  Future<void> _boot() async {
    try {
      if (widget.filePath != null) {
        _switchedToFile = true;
        await _openController(
          VideoPlayerController.file(File(widget.filePath!)),
        );
        return;
      }
      final local = await _dl.completedFile(widget.cacheKey, _ext);
      if (local != null) {
        _switchedToFile = true;
        await _openController(VideoPlayerController.file(local));
      } else {
        // Stream only — the offline save is now an explicit choice
        // (download button on the item, or the action in this app bar).
        await _openController(
          VideoPlayerController.networkUrl(Uri.parse(widget.url)),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openController(VideoPlayerController controller) async {
    await _controller?.dispose();
    _controller = controller;
    await controller.initialize();
    await controller.setLooping(false);
    if (!mounted) return;
    setState(() => _ready = true);
    await controller.play();
  }

  Future<void> _onDownload() async {
    final state = _dl.stateOf(widget.cacheKey);
    if (state.status == DownloadStatus.completed &&
        state.filePath != null &&
        !_switchedToFile) {
      _switchedToFile = true;
      final wasPlaying = _controller?.value.isPlaying ?? false;
      final position = _controller?.value.position ?? Duration.zero;
      try {
        await _openController(
          VideoPlayerController.file(File(state.filePath!)),
        );
        await _controller?.seekTo(position);
        if (!wasPlaying) await _controller?.pause();
      } catch (_) {
        // Keep streaming if the swap fails for any reason.
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dl.watch(widget.cacheKey).removeListener(_onDownload);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title.isEmpty ? 'Video' : widget.title,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          if (widget.filePath == null && widget.url.isNotEmpty)
            ValueListenableBuilder<MediaDownload>(
              valueListenable: _dl.watch(widget.cacheKey),
              builder: (context, state, _) {
                if (state.status == DownloadStatus.completed) {
                  return const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: Icon(Icons.download_done),
                  );
                }
                final active = state.status == DownloadStatus.downloading;
                return IconButton(
                  tooltip: active ? 'Pause download' : 'Save offline',
                  icon: Icon(active ? Icons.pause_circle_outline : Icons.download),
                  onPressed: () => active
                      ? _dl.pause(widget.cacheKey)
                      : _dl.start(widget.cacheKey, widget.url, ext: _ext),
                );
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          Center(child: _buildVideo()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DownloadBar(cacheKey: widget.cacheKey),
          ),
        ],
      ),
    );
  }

  Widget _buildVideo() {
    if (_error != null) {
      return const Text(
        "Couldn't play this video.",
        style: TextStyle(color: Colors.white70),
      );
    }
    final controller = _controller;
    if (!_ready || controller == null) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio == 0
          ? 16 / 9
          : controller.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(controller),
          _PlayPauseOverlay(controller: controller),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(controller, allowScrubbing: true),
          ),
        ],
      ),
    );
  }
}

class _PlayPauseOverlay extends StatefulWidget {
  final VideoPlayerController controller;
  const _PlayPauseOverlay({required this.controller});

  @override
  State<_PlayPauseOverlay> createState() => _PlayPauseOverlayState();
}

class _PlayPauseOverlayState extends State<_PlayPauseOverlay> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
  }

  void _tick() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = widget.controller.value.isPlaying;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          playing ? widget.controller.pause() : widget.controller.play(),
      child: AnimatedOpacity(
        opacity: playing ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          color: Colors.black26,
          child: const Center(
            child: Icon(Icons.play_arrow, color: Colors.white, size: 64),
          ),
        ),
      ),
    );
  }
}

/// Thin strip showing the resumable-save progress with a pause/resume
/// toggle. Hidden once the file is fully saved.
class _DownloadBar extends StatelessWidget {
  final String cacheKey;
  const _DownloadBar({required this.cacheKey});

  @override
  Widget build(BuildContext context) {
    final dl = ResumableDownloader.instance;
    return ValueListenableBuilder<MediaDownload>(
      valueListenable: dl.watch(cacheKey),
      builder: (context, state, _) {
        if (state.status == DownloadStatus.completed ||
            state.status == DownloadStatus.idle) {
          return const SizedBox.shrink();
        }
        final label = switch (state.status) {
          DownloadStatus.downloading => state.total > 0
              ? 'Saving ${(state.progress * 100).round()}%'
              : 'Saving…',
          DownloadStatus.paused => 'Save paused — tap to resume',
          DownloadStatus.failed => 'Save failed — tap to retry',
          _ => '',
        };
        final paused = state.status != DownloadStatus.downloading;
        return Material(
          color: Colors.black.withValues(alpha: 0.6),
          child: InkWell(
            onTap: () => paused ? dl.resume(cacheKey) : dl.pause(cacheKey),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(paused ? Icons.download : Icons.pause,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(label,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                  if (state.total > 0)
                    SizedBox(
                      width: 90,
                      child: LinearProgressIndicator(
                        value: state.progress,
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
