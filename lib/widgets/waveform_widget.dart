import 'package:flutter/material.dart';

/// Static Telegram/WhatsApp-style waveform for a recorded voice
/// message: fixed bars, a "played" portion highlighted up to
/// [progress], and tap/drag-to-seek.
class AudioWaveform extends StatelessWidget {
  const AudioWaveform({
    super.key,
    required this.amplitudes,
    required this.progress,
    this.onSeek,
    this.height = 32,
    this.barWidth = 3,
    this.gap = 2,
    this.playedColor,
    this.unplayedColor,
  });

  /// Normalized 0.0-1.0 bar heights, e.g. from [VoiceRecording.waveform].
  final List<double> amplitudes;

  /// Playback position as a 0.0-1.0 fraction of total duration.
  final double progress;

  /// Called with a 0.0-1.0 fraction when the user taps/drags to seek.
  /// Omit to make the waveform non-interactive.
  final ValueChanged<double>? onSeek;

  final double height;
  final double barWidth;
  final double gap;
  final Color? playedColor;
  final Color? unplayedColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final played = playedColor ?? scheme.primary;
    final unplayed = unplayedColor ?? scheme.primary.withOpacity(0.3);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: onSeek == null
          ? null
          : (details) => _seekFromLocalX(details.localPosition.dx, context),
      onHorizontalDragUpdate: onSeek == null
          ? null
          : (details) => _seekFromLocalX(details.localPosition.dx, context),
      child: SizedBox(
        height: height,
        child: CustomPaint(
          painter: _WaveformPainter(
            amplitudes: amplitudes,
            progress: progress,
            barWidth: barWidth,
            gap: gap,
            playedColor: played,
            unplayedColor: unplayed,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  void _seekFromLocalX(double x, BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final fraction = (x / box.size.width).clamp(0.0, 1.0);
    onSeek?.call(fraction);
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.barWidth,
    required this.gap,
    required this.playedColor,
    required this.unplayedColor,
  });

  final List<double> amplitudes;
  final double progress;
  final double barWidth;
  final double gap;
  final Color playedColor;
  final Color unplayedColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;
    final playedPaint = Paint()..color = playedColor;
    final unplayedPaint = Paint()..color = unplayedColor;

    final step = barWidth + gap;
    final maxBars = (size.width / step).floor().clamp(1, amplitudes.length);
    // Resample to however many bars actually fit the available
    // width, so the same stored waveform scales to any bubble size.
    final bars = _resample(amplitudes, maxBars);
    final playedBars = (bars.length * progress).round();

    for (var i = 0; i < bars.length; i++) {
      final barHeight = bars[i].clamp(0.04, 1.0) * size.height;
      final x = i * step;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - barHeight) / 2, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, i < playedBars ? playedPaint : unplayedPaint);
    }
  }

  List<double> _resample(List<double> src, int count) {
    if (src.length == count) return src;
    final out = <double>[];
    final chunk = src.length / count;
    for (var i = 0; i < count; i++) {
      final start = (i * chunk).floor();
      final end = ((i + 1) * chunk).ceil().clamp(start + 1, src.length);
      final slice = src.sublist(start, end);
      out.add(slice.reduce((a, b) => a + b) / slice.length);
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.amplitudes != amplitudes ||
        oldDelegate.progress != progress ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor;
  }
}

/// Live, growing waveform shown while recording — bars scroll in
/// from the right as [VoiceRecorderService.liveWaveform] emits new
/// amplitude ticks, matching WhatsApp's recorder view.
class LiveWaveformView extends StatelessWidget {
  const LiveWaveformView({
    super.key,
    required this.bars,
    this.height = 32,
    this.barWidth = 3,
    this.gap = 2,
    this.color,
  });

  final List<double> bars;
  final double height;
  final double barWidth;
  final double gap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final barColor = color ?? Theme.of(context).colorScheme.error;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _LiveWaveformPainter(
          bars: bars,
          barWidth: barWidth,
          gap: gap,
          color: barColor,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _LiveWaveformPainter extends CustomPainter {
  _LiveWaveformPainter({
    required this.bars,
    required this.barWidth,
    required this.gap,
    required this.color,
  });

  final List<double> bars;
  final double barWidth;
  final double gap;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final step = barWidth + gap;
    // Right-align so the newest bar sits at the right edge and older
    // ones scroll off the left as the list grows.
    var x = size.width - barWidth;
    for (var i = bars.length - 1; i >= 0 && x >= 0; i--) {
      final barHeight = bars[i].clamp(0.04, 1.0) * size.height;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - barHeight) / 2, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
      x -= step;
    }
  }

  @override
  bool shouldRepaint(covariant _LiveWaveformPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.color != color;
}