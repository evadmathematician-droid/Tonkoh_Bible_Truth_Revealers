import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Synthesizes the same dual-tone US ringback cadence (440/480 Hz, 2s on /
/// 4s off) as the web implementation in ringback_manager_web.dart, since
/// this project ships no ringback audio asset and Flutter exposes no native
/// tone-generator API. The tone is built as raw PCM/WAV bytes in memory —
/// no file system access or bundled asset required.
///
/// Uses `audioplayers`, NOT `just_audio`. `just_audio_background` is
/// registered globally for GlobalAudioPlayer's sermon playback, and it
/// allows only a single `just_audio` AudioPlayer instance for the entire
/// app's lifetime — a second `just_audio` AudioPlayer() here throws
/// PlatformException("...supports only a single player instance...") the
/// moment an outgoing call starts. `audioplayers` is a separate plugin with
/// no such restriction, so the ringback tone can play alongside the sermon
/// player (or while it's paused) without touching it at all.
class RingbackManager {
  AudioPlayer? _player;
  bool _isRinging = false;

  static final Uint8List _wavBytes = _buildWav();

  Future<void> start() async {
    if (_isRinging) return;
    _isRinging = true;
    try {
      final player = AudioPlayer();
      _player = player;
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(0.5);
      await player.play(BytesSource(_wavBytes));
    } catch (e) {
      debugPrint('RingbackManager: Failed to start ringback: $e');
      _isRinging = false;
      await _player?.dispose();
      _player = null;
    }
  }

  void stop() {
    if (!_isRinging) return;
    _isRinging = false;
    final player = _player;
    _player = null;
    player?.stop();
    player?.dispose();
  }

  static const int _sampleRate = 8000;
  static const double _toneSeconds = 2;
  static const double _cycleSeconds = 6;

  static Uint8List _buildWav() {
    final totalSamples = (_sampleRate * _cycleSeconds).round();
    final toneSamples = (_sampleRate * _toneSeconds).round();
    final pcm = Int16List(totalSamples);
    for (var i = 0; i < toneSamples; i++) {
      final t = i / _sampleRate;
      final sample = 0.5 * math.sin(2 * math.pi * 440 * t) +
          0.5 * math.sin(2 * math.pi * 480 * t);
      pcm[i] = (sample * 0.3 * 32767).round().clamp(-32768, 32767);
    }
    return _pcmToWav(pcm, _sampleRate);
  }

  static Uint8List _pcmToWav(Int16List pcm, int sampleRate) {
    const bitsPerSample = 16;
    const numChannels = 1;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataLength = pcm.lengthInBytes;

    final header = ByteData(44);
    void writeString(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeString(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    writeString(36, 'data');
    header.setUint32(40, dataLength, Endian.little);

    final bytes = Uint8List(44 + dataLength);
    bytes.setRange(0, 44, header.buffer.asUint8List());
    bytes.setRange(44, 44 + dataLength, pcm.buffer.asUint8List());
    return bytes;
  }
}
