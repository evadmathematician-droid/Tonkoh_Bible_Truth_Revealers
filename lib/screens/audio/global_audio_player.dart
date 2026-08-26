import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

class NowPlaying {
  final String id;
  final String title;
  const NowPlaying({required this.id, required this.title});
}

/// Equivalent of the Kotlin `GlobalAudioPlayer` singleton — one player
/// shared across the whole app (feed, drawer, sub-widgets), not scoped to
/// a single screen. Exposed as a ChangeNotifier so any widget can
/// `context.watch<GlobalAudioPlayer>()`, registered once in main.dart.
class GlobalAudioPlayer extends ChangeNotifier {
  GlobalAudioPlayer._internal() {
    _player.playerStateStream.listen(_onPlayerStateChanged);
    _player.positionStream.listen((pos) {
      if (!_scrubbing) {
        _positionMs = pos.inMilliseconds;
        notifyListeners();
      }
    });
    _player.durationStream.listen((d) {
      _durationMs = d?.inMilliseconds ?? 0;
      notifyListeners();
    });
  }
  static final GlobalAudioPlayer instance = GlobalAudioPlayer._internal();

  final AudioPlayer _player = AudioPlayer();

  NowPlaying? _nowPlaying;
  NowPlaying? get nowPlaying => _nowPlaying;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  int _positionMs = 0;
  int get positionMs => _positionMs;

  int _durationMs = 0;
  int get durationMs => _durationMs;

  /// Mirrors `GlobalAudioPlayer.positionMs.value = value.toInt()` in
  /// handleSeekChange — a scrub-preview write only. Doesn't move playback;
  /// call seekTo() on drag-release to commit. beginScrub() stops the
  /// real position stream from clobbering the preview mid-drag.
  set positionMs(int value) {
    _positionMs = value;
    notifyListeners();
  }

  bool _scrubbing = false;
  void beginScrub() => _scrubbing = true;

  VoidCallback? _onComplete;

  Future<void> play({
    required String id,
    required String title,
    required String filePath,
    VoidCallback? onComplete,
  }) async {
    _onComplete = onComplete;
    _nowPlaying = NowPlaying(id: id, title: title);
    _positionMs = 0;
    notifyListeners();
    // The MediaItem tag is what just_audio_background reads to populate
    // the background play/pause + progress notification — without one,
    // there's nothing for it to show at all.
    await _player.setAudioSource(AudioSource.uri(
      Uri.file(filePath),
      tag: MediaItem(id: id, title: title.isEmpty ? 'Untitled' : title),
    ));
    await _player.play();
  }

  Future<void> playUrl({
    required String id,
    required String title,
    required String url,
    VoidCallback? onComplete,
  }) async {
    _onComplete = onComplete;
    _nowPlaying = NowPlaying(id: id, title: title);
    _positionMs = 0;
    notifyListeners();
    await _player.setAudioSource(AudioSource.uri(
      Uri.parse(url),
      tag: MediaItem(id: id, title: title.isEmpty ? 'Untitled' : title),
    ));
    await _player.play();
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> seekTo(int positionMs) async {
    _scrubbing = false;
    await _player.seek(Duration(milliseconds: positionMs));
  }

  void _onPlayerStateChanged(PlayerState state) {
    _isPlaying = state.playing;
    if (state.processingState == ProcessingState.completed) {
      _isPlaying = false;
      final cb = _onComplete;
      _onComplete = null;
      notifyListeners();
      cb?.call(); // drives playNextInSequence, same as ExoPlayer's listener did
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}