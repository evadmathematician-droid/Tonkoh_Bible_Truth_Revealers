// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../ui/chat_theme.dart';
import 'package:just_audio/just_audio.dart';
import '../../data/private_message.dart';

class VoiceMessageBubble extends StatefulWidget {
  final PrivateMessage message;
  final bool isMine;
  final VoidCallback? onListened;

  const VoiceMessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onListened,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  late final AudioPlayer _player;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();

    _player.positionStream.listen((d) {
      if (mounted) setState(() => _position = d);
    });

    _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });

    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      final completed = state.processingState == ProcessingState.completed;
      setState(() {
        // Drive the play/pause icon straight off the player's own state
        // instead of flipping a bool by hand — just_audio's play() future
        // doesn't resolve until playback *finishes*, so manual toggling
        // left the icon (and the loading spinner) stuck mid-playback.
        _isPlaying = state.playing && !completed;
        if (state.processingState != ProcessingState.loading &&
            state.processingState != ProcessingState.buffering) {
          _isLoading = false;
        }
        if (completed) _position = Duration.zero;
      });
      if (completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
    });
  }

  List<double> get _waveform {
    final wave = widget.message.waveform;
    if (wave.isEmpty) return List.filled(28, 0.05);
    final maxVal = wave.reduce(math.max);
    if (maxVal == 0) return List.filled(wave.length, 0.05);
    return wave.map((v) => (v / maxVal).clamp(0.05, 1.0)).toList();
  }

  /// Maps this message's mimeType (if any) to a content type just_audio
  /// can decode. Falls back to WAV since that's what VoiceRecorderService
  /// produces for recordings made in-app.
  String get _contentType {
    final mime = widget.message.mimeType;
    if (mime.isNotEmpty) return mime;
    return 'audio/wav';
  }

  Future<void> _toggle() async {
    // Pause if it's currently playing.
    if (_player.playing) {
      await _player.pause();
      return; // playerStateStream flips _isPlaying
    }

    final url = widget.message.audioUrl;
    if (url.isEmpty) return;

    // Source already loaded from an earlier play/pause cycle — just resume.
    // NOTE: do NOT await play(); just_audio's play() future only completes
    // when playback *ends*, so awaiting it here would freeze the UI on the
    // spinner for the whole clip.
    if (_player.audioSource != null && _duration > Duration.zero) {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      unawaited(_player.play());
      return;
    }

    setState(() => _isLoading = true);
    try {
      final bytes = base64Decode(url);
      // In-memory audio source — no filesystem access, so this works
      // the same on web, Android, and iOS (unlike setFilePath, which
      // needs path_provider and has no web implementation).
      await _player.setAudioSource(_BytesAudioSource(bytes, _contentType));
      unawaited(_player.play()); // fire-and-forget, see NOTE above

      if (!widget.message.listened && widget.onListened != null) {
        widget.onListened!();
      }
    } catch (e) {
      debugPrint('Voice playback error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
    // _isLoading is cleared by the playerStateStream listener once the
    // player leaves the loading/buffering state.
  }

  double get _progress {
    final totalMs = _duration.inMilliseconds;
    if (totalMs == 0) return 0;
    return (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wave = _waveform;
    final progress = _progress;
    final listened = widget.message.listened;

    final palette = ChatTheme.of(context);
    final fgColor = !widget.isMine && listened
        ? palette.incomingMeta
        : palette.text(widget.isMine);
    final inactiveColor = palette.text(widget.isMine).withValues(alpha: 0.35);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _isLoading ? null : _toggle,
          child: _isLoading
              ? SizedBox(
            width: 32,
            height: 32,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: fgColor,
              ),
            ),
          )
              : Icon(
            _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
            color: fgColor,
            size: 32,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 32,
          width: 120,
          child: CustomPaint(
            painter: _WaveformPainter(
              samples: wave,
              progress: progress,
              activeColor: fgColor,
              inactiveColor: inactiveColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatDuration(_isPlaying ? _position : Duration(seconds: widget.message.duration)),
          style: TextStyle(color: fgColor, fontSize: 12),
        ),
        if (!listened && !widget.isMine) ...[
          const SizedBox(width: 6),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Feeds already-decoded bytes to just_audio without touching disk.
/// Works on web, Android, and iOS — unlike setFilePath, which requires
/// path_provider and has no web implementation.
class _BytesAudioSource extends StreamAudioSource {
  final Uint8List _bytes;
  final String _contentType;

  _BytesAudioSource(this._bytes, this._contentType) : super(tag: 'VoiceMessage');

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

class _WaveformPainter extends CustomPainter {
  final List<double> samples;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  _WaveformPainter({
    required this.samples,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final count = samples.length;
    final totalBarWidth = size.width / count;
    final barW = totalBarWidth * 0.65;
    final gapW = totalBarWidth * 0.35;
    final activeCount = (progress * count).round().clamp(0, count);

    for (int i = 0; i < count; i++) {
      final x = i * totalBarWidth + gapW / 2;
      final barHeight = math.max(2.0, samples[i] * size.height);
      final y = (size.height - barHeight) / 2;

      final paint = Paint()
        ..color = i < activeCount ? activeColor : inactiveColor
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barW, barHeight),
          Radius.circular(barW / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) {
    return old.progress != progress || old.samples != samples;
  }
}