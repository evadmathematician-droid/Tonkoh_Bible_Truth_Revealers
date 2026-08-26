import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// pubspec.yaml: record: ^5.1.0 (already in yours) — no path_provider
/// needed for this version.
///
/// Why this version instead of writing to a file: `record`'s file-based
/// start(path: ...) needs somewhere on disk to write to, which is what
/// path_provider's getTemporaryDirectory() was for — and that plugin
/// has no web implementation, hence the MissingPluginException in
/// Chrome. This version uses startStream() instead, which both mobile
/// and web support: raw audio bytes arrive as they're captured, kept
/// entirely in memory, and assembled into a playable WAV file only
/// once recording stops. Same technique WhatsApp Web/Telegram Web use
/// for in-browser voice notes.
///
/// API matches what PrivateChatScreen calls: startRecording() /
/// pauseRecording() / resumeRecording() / cancelRecording() /
/// stopRecording() -> seconds (int) / encodeRecordingToBase64().
class VoiceRecorderService {
  VoiceRecorderService({this.sampleRate = 16000, int maxLiveBars = 60})
      : _maxLiveBars = maxLiveBars;

  final int sampleRate;
  final int _maxLiveBars;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _streamSub;
  final BytesBuilder _pcmBuffer = BytesBuilder(copy: false);
  final List<double> _rawSamples = [];
  final StreamController<List<double>> _liveBarsController =
  StreamController<List<double>>.broadcast();

  DateTime? _startedAt;
  Duration _pausedAccum = Duration.zero;
  DateTime? _pausedAt;

  Uint8List? _lastWavBytes;
  List<double> _lastWaveform = const [];

  /// Live bars for the "recording..." UI, most recent last.
  Stream<List<double>> get liveWaveform => _liveBarsController.stream;

  /// Fixed-length (40 bar) waveform from the most recently completed
  /// recording. Populated after [stopRecording] returns.
  List<double> get lastWaveform => _lastWaveform;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> startRecording() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }

    _pcmBuffer.clear();
    _rawSamples.clear();
    _pausedAccum = Duration.zero;
    _pausedAt = null;
    _lastWavBytes = null;
    _startedAt = DateTime.now();

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _streamSub = stream.listen(_onChunk);
  }

  void _onChunk(Uint8List chunk) {
    _pcmBuffer.add(chunk);

    // Peak amplitude for this chunk, computed straight from the raw
    // 16-bit PCM samples — identical on web and native, so it
    // doesn't rely on onAmplitudeChanged (which isn't available in
    // stream mode on every platform).
    double peak = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final sample = chunk[i] | (chunk[i + 1] << 8);
      final signed = sample >= 32768 ? sample - 65536 : sample;
      final normalized = signed.abs() / 32768.0;
      if (normalized > peak) peak = normalized;
    }
    _rawSamples.add(peak);

    final live = _rawSamples.length <= _maxLiveBars
        ? List<double>.from(_rawSamples)
        : _rawSamples.sublist(_rawSamples.length - _maxLiveBars);
    _liveBarsController.add(live);
  }

  Future<void> pauseRecording() async {
    await _recorder.pause();
    _pausedAt = DateTime.now();
  }

  Future<void> resumeRecording() async {
    await _recorder.resume();
    if (_pausedAt != null) {
      _pausedAccum += DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
    }
  }

  Future<void> cancelRecording() async {
    await _streamSub?.cancel();
    _streamSub = null;
    await _recorder.cancel();
    _pcmBuffer.clear();
    _rawSamples.clear();
    _startedAt = null;
    _pausedAt = null;
  }

  /// Stops recording, wraps the buffered PCM bytes as a WAV in
  /// memory, stores the fixed-bar waveform in [lastWaveform], and
  /// returns elapsed seconds (excluding paused time).
  Future<int> stopRecording({int barCount = 40}) async {
    await _recorder.stop();
    await _streamSub?.cancel();
    _streamSub = null;

    final pcm = _pcmBuffer.takeBytes();
    _lastWavBytes = _wrapPcmAsWav(pcm, sampleRate: sampleRate, numChannels: 1);
    _lastWaveform = _downsample(_rawSamples, barCount);

    var elapsed = Duration.zero;
    if (_startedAt != null) {
      elapsed = DateTime.now().difference(_startedAt!) - _pausedAccum;
    }
    _startedAt = null;
    _pausedAt = null;

    return elapsed.inSeconds.clamp(0, 1 << 30);
  }

  /// Base64-encodes the WAV bytes assembled in [stopRecording] —
  /// matches your existing pattern for PrivateMessage.audioUrl.
  /// Purely in-memory, so this works the same on web and mobile.
  Future<void> encodeRecordingToBase64({
    required void Function(String base64Audio) onSuccess,
    required void Function(Object error) onFailure,
  }) async {
    final bytes = _lastWavBytes;
    if (bytes == null || bytes.isEmpty) {
      onFailure(StateError('No recording available to encode'));
      return;
    }
    try {
      onSuccess(base64Encode(bytes));
    } catch (e) {
      onFailure(e);
    }
  }

  Uint8List _wrapPcmAsWav(
      Uint8List pcm, {
        required int sampleRate,
        required int numChannels,
      }) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataLength = pcm.length;
    final header = BytesBuilder();

    void writeString(String s) => header.add(s.codeUnits);
    void writeUint32(int v) => header.add([
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ]);
    void writeUint16(int v) => header.add([v & 0xff, (v >> 8) & 0xff]);

    writeString('RIFF');
    writeUint32(36 + dataLength);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1); // PCM
    writeUint16(numChannels);
    writeUint32(sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(bitsPerSample);
    writeString('data');
    writeUint32(dataLength);

    final result = BytesBuilder();
    result.add(header.takeBytes());
    result.add(pcm);
    return result.takeBytes();
  }

  /// Averages [samples] down to exactly [barCount] bars, then scales
  /// so the loudest bar hits ~1.0 — otherwise quiet recordings look
  /// like a flat line even though it's not silence.
  List<double> _downsample(List<double> samples, int barCount) {
    if (samples.isEmpty) return List.filled(barCount, 0.02);
    final result = <double>[];
    final chunk = samples.length / barCount;
    for (var i = 0; i < barCount; i++) {
      final start = (i * chunk).floor();
      final end = math.min(samples.length, ((i + 1) * chunk).ceil());
      if (start >= end) {
        result.add(result.isEmpty ? 0.02 : result.last);
        continue;
      }
      final slice = samples.sublist(start, end);
      result.add(slice.reduce((a, b) => a + b) / slice.length);
    }
    final maxVal = result.reduce(math.max);
    if (maxVal <= 0.001) return List.filled(barCount, 0.02);
    return result.map((v) => (v / maxVal).clamp(0.04, 1.0)).toList();
  }

  void dispose() {
    _streamSub?.cancel();
    _liveBarsController.close();
    _recorder.dispose();
  }
}