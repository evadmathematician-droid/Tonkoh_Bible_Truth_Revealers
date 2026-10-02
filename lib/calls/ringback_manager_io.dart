import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Outgoing-call ringback tone for the `dart:io` platforms (Android, iOS,
/// desktop). Loops a short bundled ringback asset for as long as the caller
/// is waiting for the callee to answer.
///
/// The web build has its own WebAudio-synthesised implementation in
/// `ringback_manager_web.dart`; the conditional export in
/// `ringback_manager.dart` picks between them. Keep the public surface
/// (`start()` / `stop()` / `dispose()`) identical across both so the shared
/// call sites in [OutgoingCallScreen] compile on every platform.
///
/// Concurrency notes:
///  * just_audio throws `Invalid argument: Cannot complete a future with
///    itself` ("Loading interrupted") when a `setAsset()` load is still in
///    flight and a *second* `setAsset()` — or a `dispose()` — hits the same
///    [AudioPlayer]. `setAsset`/`play`/`dispose` therefore go through a
///    single serialised chain ([_chain]).
///  * `stop()`, however, must be reliable *immediately* — the caller hangs
///    up and the tone has to die at once, even if `start()`'s load future
///    is still pending and even with no network. So `stop()` does three
///    things: clears the intent flag (so an in-flight `start()` aborts at
///    its next checkpoint), calls `player.stop()` out-of-band right now,
///    and also queues an ordered stop as a backstop. It never rethrows.
class RingbackManager {
  static const _asset = 'assets/sounds/ringback.wav';

  AudioPlayer? _player;
  bool _wantRinging = false;
  bool _disposed = false;

  Future<void> _chain = Future<void>.value();

  Future<void> _enqueue(Future<void> Function() action) {
    final run = _chain
        .then((_) => action())
        .catchError((Object e) =>
            debugPrint('RingbackManager: chained op failed (ignored): $e'));
    _chain = run;
    return run;
  }

  Future<void> start() {
    return _enqueue(() async {
      if (_disposed || _wantRinging) return;
      _wantRinging = true;
      final player = _player ??= AudioPlayer();
      try {
        await player.setAsset(_asset);
        if (_abortStart(player)) return;
        await player.setLoopMode(LoopMode.one);
        await player.setVolume(1.0);
        if (_abortStart(player)) return;
        await player.play();
        if (_abortStart(player)) return;
        debugPrint('RingbackManager: ringback playing');
      } catch (e) {
        // Missing asset / audio-focus denial / interrupted load — the call
        // still works, it's just silent. Never rethrow.
        debugPrint('RingbackManager: failed to start ringback: $e');
      }
    });
  }

  /// True when a stop()/dispose() landed while start() was mid-load — in
  /// which case halt whatever did get loaded and give up on starting.
  bool _abortStart(AudioPlayer player) {
    if (_wantRinging && !_disposed) return false;
    debugPrint('RingbackManager: start() aborted mid-load (stop/dispose won)');
    unawaited(_rawStop(player));
    return true;
  }

  void stop() {
    debugPrint('RingbackManager: stop() requested '
        '(wantRinging=$_wantRinging, hasPlayer=${_player != null})');
    _wantRinging = false;
    final player = _player;
    if (player != null) {
      // Out-of-band: don't wait for the serialised chain (which may still be
      // loading the asset). player.stop() is safe to call concurrently with
      // a pending load — just_audio ends that load with "Loading
      // interrupted", which start() catches.
      _rawStop(player).then(
        (_) => debugPrint('RingbackManager: stop() halted playback'),
        onError: (Object e) =>
            debugPrint('RingbackManager: stop() error (ignored): $e'),
      );
    }
    // Backstop: also run a stop after anything currently queued, so a stop()
    // that raced ahead of a not-yet-issued play() still catches it.
    _enqueue(() async {
      final p = _player;
      if (p != null) await _rawStop(p);
    });
  }

  Future<void> _rawStop(AudioPlayer player) async {
    try {
      await player.stop();
    } catch (e) {
      debugPrint('RingbackManager: player.stop() threw (ignored): $e');
    }
  }

  void dispose() {
    debugPrint('RingbackManager: dispose() requested');
    _wantRinging = false;
    _disposed = true;
    final player = _player;
    if (player != null) unawaited(_rawStop(player));
    // Ordered: releasing the player mid-load is the "Cannot complete a
    // future with itself" crash, so wait for the chain to drain first.
    _enqueue(() async {
      final p = _player;
      _player = null;
      if (p == null) return;
      try {
        await p.dispose();
        debugPrint('RingbackManager: player disposed');
      } catch (e) {
        debugPrint('RingbackManager: dispose() threw (ignored): $e');
      }
    });
  }
}
