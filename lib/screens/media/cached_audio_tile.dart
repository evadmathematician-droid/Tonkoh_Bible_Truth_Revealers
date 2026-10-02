// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../services/resumable_downloader.dart';
import '../../services/share_service.dart';
import '../../widgets/media_download_button.dart';

/// Compact audio player for a chat audio attachment.
///
///  * The play button only plays. Remote (`https://…`) sources stream
///    progressively; playback switches to the local file once the
///    separate download control has finished saving it.
///  * The circular [MediaDownloadButton] beside it is the download
///    control: single tap pauses/resumes, double tap stops the download
///    and playback.
///  * Legacy base64 sources (older messages) decode in-memory, no network.
class CachedAudioTile extends StatefulWidget {
  final String messageId;
  final String source; // https URL or raw base64
  final String fileName;
  final String mimeType;
  final bool isMine;
  final int durationSeconds;

  const CachedAudioTile({
    super.key,
    required this.messageId,
    required this.source,
    required this.isMine,
    this.fileName = '',
    this.mimeType = '',
    this.durationSeconds = 0,
  });

  bool get _isRemote =>
      source.startsWith('http://') || source.startsWith('https://');

  @override
  State<CachedAudioTile> createState() => _CachedAudioTileState();
}

class _CachedAudioTileState extends State<CachedAudioTile> {
  static const _ext = '.mp3';

  AudioPlayer? _player;
  bool _loading = false;
  bool _playing = false;
  bool _loadedFromFile = false;
  Duration _position = Duration.zero;
  Duration? _duration;

  Color get _fg => widget.isMine ? Colors.white : const Color(0xFF102A72);
  ResumableDownloader get _dl => ResumableDownloader.instance;

  @override
  void initState() {
    super.initState();
    if (widget._isRemote) {
      _dl.watch(widget.messageId).addListener(_onDownload);
    }
  }

  @override
  void dispose() {
    if (widget._isRemote) {
      _dl.watch(widget.messageId).removeListener(_onDownload);
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _onDownload() async {
    final state = _dl.stateOf(widget.messageId);
    if (state.status == DownloadStatus.completed &&
        state.filePath != null &&
        !_loadedFromFile &&
        _player != null &&
        !_player!.playing) {
      // Next play will pick up the local file; nothing to do mid-playback.
      _loadedFromFile = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _prepare() async {
    if (_player != null && !_needsReload()) return;
    await _player?.dispose();
    final player = AudioPlayer();
    _player = player;

    player.playerStateStream.listen((state) {
      if (!mounted) return;
      final completed = state.processingState == ProcessingState.completed;
      setState(() {
        _playing = state.playing && !completed;
        if (state.processingState != ProcessingState.loading &&
            state.processingState != ProcessingState.buffering) {
          _loading = false;
        }
      });
      if (completed) {
        player.pause();
        player.seek(Duration.zero);
      }
    });
    player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });

    if (widget._isRemote) {
      final local = await _dl.completedFile(widget.messageId, _ext);
      if (local != null) {
        _loadedFromFile = true;
        await player.setFilePath(local.path);
      } else {
        _loadedFromFile = false;
        // First play: stream progressively AND start a background save so
        // replays (and offline) come from disk. Nothing was fetched before
        // this tap.
        _dl.start(widget.messageId, widget.source, ext: _ext);
        await player.setUrl(widget.source); // progressive stream
      }
    } else {
      final bytes = base64Decode(widget.source);
      await player.setAudioSource(_BytesSource(
        bytes,
        widget.mimeType.isNotEmpty ? widget.mimeType : 'audio/mpeg',
      ));
    }
  }

  bool _needsReload() {
    // Reload if the file finished downloading since we last set the source.
    if (!widget._isRemote || _loadedFromFile) return false;
    return _dl.stateOf(widget.messageId).status == DownloadStatus.completed;
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player != null && player.playing) {
      await player.pause();
      return;
    }
    setState(() => _loading = true);
    try {
      await _prepare();
      final p = _player!;
      if (p.processingState == ProcessingState.completed) {
        await p.seek(Duration.zero);
      }
      unawaited(p.play());
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't play this audio.")),
        );
      }
    }
  }

  void _stopEverything() {
    _player?.pause();
    _player?.seek(Duration.zero);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration ?? Duration(seconds: widget.durationSeconds);
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return SizedBox(
      width: 236,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _loading
              ? SizedBox(
                  width: 32,
                  height: 32,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: _fg),
                  ),
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(
                    _playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: _fg,
                    size: 32,
                  ),
                  onPressed: _toggle,
                ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.fileName.isEmpty ? 'Audio' : widget.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _fg, fontSize: 12),
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: _fg.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation(_fg),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  total > Duration.zero
                      ? '${_fmt(_position)} / ${_fmt(total)}'
                      : '',
                  style: TextStyle(color: _fg.withValues(alpha: 0.8), fontSize: 10),
                ),
              ],
            ),
          ),
          if (widget._isRemote) ...[
            const SizedBox(width: 6),
            MediaDownloadButton(
              cacheKey: widget.messageId,
              url: widget.source,
              ext: _ext,
              size: 30,
              color: _fg,
              background: _fg.withValues(alpha: 0.12),
              onStopPlayback: _stopEverything,
            ),
          ],
          const SizedBox(width: 2),
          GestureDetector(
            onTap: () => ShareService.instance.shareApp(),
            child: Icon(Icons.share, color: _fg, size: 18),
          ),
        ],
      ),
    );
  }
}

class _BytesSource extends StreamAudioSource {
  final Uint8List _bytes;
  final String _contentType;
  _BytesSource(this._bytes, this._contentType) : super(tag: 'ChatAudio');

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: _contentType,
    );
  }
}
