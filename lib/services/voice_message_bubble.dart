import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
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
  // Uses `audioplayers`, NOT `just_audio`. `just_audio_background` is
  // registered globally in main.dart for GlobalAudioPlayer's sermon
  // playback, and it allows only a single `just_audio` AudioPlayer
  // instance for the entire app's lifetime — a second `just_audio`
  // AudioPlayer() here (one gets created per voice-note bubble) throws
  // PlatformException("...supports only a single player instance...")
  // the moment setAudioSource()/play() actually runs. That exception was
  // being swallowed by _toggle()'s catch block, so tapping play looked
  // like a dead button: no audio, no error, nothing. Same restriction and
  // same fix already applied to the call ringback tone — see
  // ringback_manager_io.dart. `audioplayers` has no such limit, so it can
  // play voice notes alongside (or while paused against) the sermon
  // player without touching it at all.
  late final AudioPlayer _player;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _sourceLoaded = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();

    _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });

    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });

    // Single source of truth for play/pause state, driven off the
    // player's own state stream rather than flags set by hand around the
    // setSourceBytes()/play() calls in _toggle().
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state == PlayerState.playing;
        if (state == PlayerState.completed) {
          // audioplayers releases the source on completion (default
          // ReleaseMode.release), so the next play needs to re-set it
          // rather than just resume().
          _position = Duration.zero;
          _sourceLoaded = false;
        }
      });
    });
  }

  List<double> get _waveform {
    final wave = widget.message.waveform;
    if (wave.isEmpty) return List.filled(28, 0.05);
    final maxVal = wave.reduce(math.max);
    if (maxVal == 0) return List.filled(wave.length, 0.05);
    return wave.map((v) => (v / maxVal).clamp(0.05, 1.0)).toList();
  }

  /// Maps this message's mimeType (if any) to a content type the player
  /// can decode. Falls back to WAV since that's what VoiceRecorderService
  /// produces for recordings made in-app.
  String get _contentType {
    final mime = widget.message.mimeType;
    if (mime.isNotEmpty) return mime;
    return 'audio/wav';
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }

    final url = widget.message.audioUrl;
    if (url.isEmpty) return;

    // Already loaded from a previous play/pause cycle — just resume,
    // no need to re-decode/re-set the source.
    if (_sourceLoaded) {
      await _player.resume();
      return;
    }

    setState(() => _isLoading = true);
    try {
      final bytes = base64Decode(url);
      // In-memory audio source — no filesystem access, so this works
      // the same on web, Android, and iOS.
      await _player.play(BytesSource(bytes, mimeType: _contentType));
      _sourceLoaded = true;

      if (!widget.message.listened && widget.onListened != null) {
        widget.onListened!();
      }
    } catch (e) {
      debugPrint('Voice playback error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't play voice message.")),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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

    final fgColor = widget.isMine
        ? Colors.white
        : (listened ? Colors.grey.shade700 : Colors.black87);
    final inactiveColor = widget.isMine
        ? Colors.white.withOpacity(0.35)
        : Colors.grey.shade400;

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