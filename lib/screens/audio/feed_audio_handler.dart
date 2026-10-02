import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// The one [FeedAudioHandler] for the whole app, created by
/// `AudioService.init(...)` in `main.dart` and read from everywhere via
/// [GlobalAudioPlayer]. `late` because it isn't valid until that init runs.
late FeedAudioHandler feedAudioHandler;

/// audio_service handler that wraps the single [AudioPlayer] used for the
/// audio-feed screen, so Android renders a real media-style notification
/// (title, artwork, play / pause / seek) and lock-screen + Bluetooth /
/// headset controls, all kept in sync with in-app playback through one
/// source of truth.
///
/// The app's other `AudioPlayer` instances (ringback tone, chat voice notes,
/// the admin-approval preview) are deliberately NOT routed through here —
/// they're short, in-app-only sounds that shouldn't post a "now playing"
/// notification. Only the feed player, which plays full sermons the user
/// listens to with the screen off, needs the media session.
class FeedAudioHandler extends BaseAudioHandler with SeekHandler {
  /// Exposed so [GlobalAudioPlayer] can keep listening to the raw position /
  /// duration / player-state streams it already relied on for the in-app UI.
  final AudioPlayer player = AudioPlayer();

  FeedAudioHandler() {
    // Player events → the PlaybackState the OS notification reads.
    player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    // Keep the notification's duration/progress bar honest once the source
    // reports its real length.
    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (item != null && d != null && item.duration != d) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });
  }

  /// Swap the current source and start playing. [item] is what the
  /// notification shows.
  Future<void> loadAndPlay(MediaItem item, AudioSource source) async {
    mediaItem.add(item);
    try {
      await player.setAudioSource(source);
    } catch (e) {
      // A bad URL / missing file surfaces through playbackState's error
      // processing state; don't let it throw out of the play button.
      debugPrint('FeedAudioHandler: setAudioSource failed: $e');
    }
    await player.play();
  }

  // ── Controls (also invoked by the notification / lock screen / headset) ──
  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    final playing = player.playing;
    return PlaybackState(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: switch (player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }
}

/// The app icon, copied to a cache file once, used as fallback notification
/// artwork when a sermon has no image of its own. `null` if the copy fails.
Uri? _fallbackArtUri;
bool _fallbackArtTried = false;

Future<Uri?> defaultArtUri() async {
  if (_fallbackArtTried) return _fallbackArtUri;
  _fallbackArtTried = true;
  try {
    final bytes = await rootBundle.load('assets/icon/icon.png');
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/notif_art.png');
    if (!await f.exists()) {
      await f.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    _fallbackArtUri = Uri.file(f.path);
  } catch (e) {
    debugPrint('defaultArtUri: could not prepare fallback art: $e');
    _fallbackArtUri = null;
  }
  return _fallbackArtUri;
}
