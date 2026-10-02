import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'feed_audio_handler.dart';

class NowPlaying {
  final String id;
  final String title;
  const NowPlaying({required this.id, required this.title});
}

/// Equivalent of the Kotlin `GlobalAudioPlayer` singleton — one player
/// shared across the whole app (feed, drawer, sub-widgets), not scoped to
/// a single screen. Exposed as a ChangeNotifier so any widget can
/// `context.watch<GlobalAudioPlayer>()`, registered once in main.dart.
///
/// Playback is routed through [feedAudioHandler] (audio_service) so a proper
/// Android media notification + lock-screen controls appear and stay in
/// sync: this class is the in-app read model, the handler is the OS-facing
/// one, and both are driven by the same underlying [AudioPlayer]. The
/// notification's play / pause / seek buttons call the handler, which moves
/// the same player, which updates the streams this class listens to — so the
/// UI icon never drifts from the notification.
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

  /// The raw player, owned by the audio_service handler. Reading its streams
  /// is fine; mutate it only through the handler (via the methods below) so
  /// the media session stays in step.
  AudioPlayer get _player => feedAudioHandler.player;

  NowPlaying? _nowPlaying;
  NowPlaying? get nowPlaying => _nowPlaying;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  bool _isBuffering = false;

  /// True while the player is loading / buffering a source — used to show a
  /// spinner on the row whose audio is being fetched on demand.
  bool get isBuffering => _isBuffering;

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
    String? artist,
    Uri? artUri,
    VoidCallback? onComplete,
  }) async {
    _onComplete = onComplete;
    _nowPlaying = NowPlaying(id: id, title: title);
    _positionMs = 0;
    notifyListeners();
    await feedAudioHandler.loadAndPlay(
      await _mediaItem(id: id, title: title, artist: artist, artUri: artUri),
      AudioSource.uri(Uri.file(filePath)),
    );
  }

  Future<void> playUrl({
    required String id,
    required String title,
    required String url,
    String? artist,
    Uri? artUri,
    VoidCallback? onComplete,
  }) async {
    _onComplete = onComplete;
    _nowPlaying = NowPlaying(id: id, title: title);
    _positionMs = 0;
    notifyListeners();
    await feedAudioHandler.loadAndPlay(
      await _mediaItem(id: id, title: title, artist: artist, artUri: artUri),
      AudioSource.uri(Uri.parse(url)),
    );
  }

  Future<MediaItem> _mediaItem({
    required String id,
    required String title,
    String? artist,
    Uri? artUri,
  }) async {
    return MediaItem(
      id: id,
      title: title.isEmpty ? 'Untitled' : title,
      artist: (artist == null || artist.trim().isEmpty)
          ? 'Tonkoh Bible Truth Revealers'
          : artist.trim(),
      artUri: artUri ?? await defaultArtUri(),
      duration: _durationMs > 0 ? Duration(milliseconds: _durationMs) : null,
    );
  }

  Future<void> pause() => feedAudioHandler.pause();
  Future<void> resume() => feedAudioHandler.play();

  Future<void> seekTo(int positionMs) async {
    _scrubbing = false;
    await feedAudioHandler.seek(Duration(milliseconds: positionMs));
  }

  void _onPlayerStateChanged(PlayerState state) {
    _isPlaying = state.playing;
    _isBuffering = state.processingState == ProcessingState.loading ||
        state.processingState == ProcessingState.buffering;
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
}
