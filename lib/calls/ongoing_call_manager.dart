import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../calls/call_connection_monitor.dart';
import '../calls/call_signaling_repository.dart';
import '../calls/web_rtc_client.dart';
import 'call_foreground.dart';
import 'call_notifications.dart';

class OngoingCallManager {
  static final OngoingCallManager instance = OngoingCallManager._();
  OngoingCallManager._();

  final CallSignalingRepository _signaling = CallSignalingRepository();

  WebRtcClient? _webRtcClient;
  String? _callId;
  String? _callType;
  bool? _isCaller;
  String _peerName = 'Unknown';
  String _statusText = 'Connecting…';

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _remoteTrackController = StreamController<MediaStreamTrack>.broadcast();
  Stream<MediaStreamTrack> get remoteTrackStream => _remoteTrackController.stream;

  bool _hasEnded = false;
  bool _isInitialized = false;

  StreamSubscription<DatabaseEvent>? _stateSub;
  StreamSubscription<DatabaseEvent>? _offerSub;
  StreamSubscription<DatabaseEvent>? _answerSub;
  StreamSubscription<DatabaseEvent>? _callerCandidatesSub;
  StreamSubscription<DatabaseEvent>? _calleeCandidatesSub;

  CallConnectionMonitor? _monitor;

  // Post-connect stability. Once the call is up, a drop (`disconnected` /
  // `failed`) previously just changed the status text to "Reconnecting…"
  // forever — the freeze users reported. Now a drop starts a recovery
  // window; if ICE hasn't re-established by the time it elapses the call is
  // ended cleanly with a message rather than hanging.
  Timer? _recoveryTimer;
  Timer? _statsTimer;
  bool _everConnected = false;
  static const _recoverAfterDisconnect = Duration(seconds: 30);
  static const _recoverAfterFailed = Duration(seconds: 15);

  void _onConnectionStateChanged(RTCPeerConnectionState state) {
    _monitor?.onPeerConnectionStateChange(state);
    debugPrint('OngoingCallManager: peer connection state -> $state');

    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _everConnected = true;
        _recoveryTimer?.cancel();
        _recoveryTimer = null;
        _statusText = 'Connected';
        _startStatsLogging();
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _statusText = 'Reconnecting…';
        // `disconnected` is often transient — ICE frequently heals it back
        // to `connected` on its own within a few seconds. Give it a window.
        _armRecovery(_recoverAfterDisconnect);
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _statusText = 'Reconnecting…';
        _armRecovery(_recoverAfterFailed);
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        if (_everConnected) {
          _statusText = 'Call ended';
          endCall();
        }
        break;
      default:
        if (!_everConnected) _statusText = 'Connecting…';
    }

    _statusController.add(_statusText);
    _updateNotification();
  }

  void _armRecovery(Duration window) {
    if (_hasEnded) return;
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(window, () {
      if (_hasEnded) return;
      debugPrint('OngoingCallManager: not recovered within '
          '${window.inSeconds}s — ending call');
      _statusText = 'Call lost — connection dropped';
      _statusController.add(_statusText);
      endCall();
    });
  }

  void _startStatsLogging() {
    _statsTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      _webRtcClient?.logCallStats();
    });
  }

  Future<void> startCall({
    required String callId,
    required String callType,
    required bool isCaller,
    required String peerName,
    required bool cameraGranted,
  }) async {
    if (_isInitialized) {
      await _updateNotification();
      return;
    }

    _callId = callId;
    _callType = callType;
    _isCaller = isCaller;
    _peerName = peerName;
    _hasEnded = false;
    _isInitialized = true;
    _remoteSdpHandled = false;
    _everConnected = false;
    _statusText = 'Connecting…';

    // If this client dies mid-call without a clean hang-up (process killed,
    // crash, network gone), Firebase writes ENDED for us so the peer isn't
    // left in "Connecting…" / connected-forever. Disarmed in endCall().
    await _signaling.armDisconnectEnd(callId);

    await CallNotifications.showOngoingCall(
      callType: callType,
      peerName: peerName,
      statusText: _statusText,
    );

    // Keep the process alive if the call screen is backgrounded mid-call.
    unawaited(CallForegroundService.start(
      callType: callType,
      peerName: peerName,
    ));

    _monitor = CallConnectionMonitor(
      timeoutMs: 30000,
      onTimeout: () {
        debugPrint('OngoingCallManager: Monitor timeout — ending call');
        endCall();
      },
    );

    await _initCall(cameraGranted);
    _monitor!.start();
  }

  Future<void> _initCall(bool cameraGranted) async {
    final isVideo = _callType == 'video';

    // Attach the remote-hangup listener BEFORE the long media/ICE setup
    // (which includes a permission dialog) so a hang-up during "Connecting…"
    // is still caught instead of building a peer connection for a dead call.
    _listenForRemoteHangup();

    _webRtcClient = WebRtcClient(
      onLocalIceCandidate: (candidate) {
        if (_callId != null && _isCaller != null) {
          _signaling.sendIceCandidate(_callId!, _isCaller!, candidate);
        }
      },
      onRemoteVideoTrack: (track) {
        _remoteTrackController.add(track);
      },
      onConnectionStateChanged: _onConnectionStateChanged,
    );

    await _webRtcClient!.initFactory();

    // For a video call, always ask setupLocalMedia for video and let
    // getUserMedia be the source of truth — its try/catch falls back to
    // audio-only if the camera really is unavailable. Gating on
    // `cameraGranted` here meant a permission status that read back as
    // "not granted" a moment too late (common on XOS/Infinix) permanently
    // suppressed the phone's outgoing video for the whole call.
    final wantVideo = isVideo && cameraGranted;
    final localStream = await _webRtcClient!.setupLocalMedia(isVideo);
    if (isVideo && !wantVideo) {
      debugPrint('OngoingCallManager: camera not pre-granted; relied on '
          'getUserMedia — video track present: '
          '${localStream.getVideoTracks().isNotEmpty}');
    }

    if (_abortIfEnded()) return; // hung up during getUserMedia / perm dialog

    final iceServers = await _webRtcClient!.fetchIceServers();
    if (_abortIfEnded()) return;
    await _webRtcClient!.setupPeerConnection(localStream, iceServers);

    // Put Android's audio stack into call ("in communication") mode so the
    // mic is hot and routing works like a real phone call — without this,
    // voice calls could come through with no audible mic/earpiece path.
    // No-op on web.
    try {
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.communication,
      );
    } catch (_) {}
    // Local mic starts ENABLED, always. (setupLocalMedia already enables the
    // track; this guards against any stale mute state on the singleton.)
    _webRtcClient!.setAudioEnabled(true);
    // Video call → loudspeaker; voice call → earpiece, like WhatsApp.
    await setSpeaker(isVideo);

    if (_abortIfEnded()) return;
    if (_isCaller == true) {
      await _startAsCaller();
    } else {
      await _startAsCallee();
    }
  }

  /// The call was hung up (locally or by the peer) while [_initCall] was
  /// still awaiting media / ICE setup. Release the half-built WebRTC client
  /// we just created — endCall() ran before it existed and won't retry —
  /// and bail out of the rest of setup.
  bool _abortIfEnded() {
    if (!_hasEnded) return false;
    debugPrint('OngoingCallManager: setup aborted — call already ended');
    try {
      _webRtcClient?.endCall();
    } catch (_) {}
    _webRtcClient = null;
    return true;
  }

  // Set once the remote SDP has been handled, so a replayed Firebase value
  // event doesn't drive a second setRemoteDescription (which aborts
  // negotiation). Mirrors OngoingCallService.remoteDescriptionSet on Android.
  bool _remoteSdpHandled = false;

  Future<void> _startAsCaller() async {
    final callId = _callId!;
    final sdp = await _webRtcClient!.createOffer();
    await _signaling.sendOffer(callId, sdp);

    _answerSub = _signaling.observeAnswer(callId, (answerSdp) async {
      if (_remoteSdpHandled) return;
      _remoteSdpHandled = true;
      await _answerSub?.cancel();
      _answerSub = null;
      try {
        await _webRtcClient!.setRemoteAnswer(answerSdp);
      } catch (e) {
        debugPrint('OngoingCallManager: answer rejected — ending call: $e');
        endCall();
      }
    });

    _calleeCandidatesSub = _signaling.observeRemoteIceCandidates(
      callId,
      true,
          (candidate) => _webRtcClient!.addRemoteIceCandidate(candidate),
    );
  }

  Future<void> _startAsCallee() async {
    final callId = _callId!;

    _offerSub = _signaling.observeOffer(callId, (offerSdp) async {
      if (_remoteSdpHandled) return;
      _remoteSdpHandled = true;
      await _offerSub?.cancel();
      _offerSub = null;
      try {
        await _webRtcClient!.setRemoteOffer(offerSdp, onSetSuccess: () async {
          final answerSdp = await _webRtcClient!.createAnswer();
          await _signaling.sendAnswer(callId, answerSdp);
        });
      } catch (e) {
        debugPrint('OngoingCallManager: offer rejected — ending call: $e');
        endCall();
      }
    });

    _callerCandidatesSub = _signaling.observeRemoteIceCandidates(
      callId,
      false,
          (candidate) => _webRtcClient!.addRemoteIceCandidate(candidate),
    );
  }

  void _listenForRemoteHangup() {
    _stateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(_callId!)
        .child('state')
        .onValue
        .listen((event) {
      final state = event.snapshot.value as String?;
      // null == the call doc was removed. Attaches while state is ACCEPTED,
      // so the immediate first event never matches these.
      if (state == null ||
          state == 'ENDED' ||
          state == 'DECLINED' ||
          state == 'MISSED' ||
          state == 'CANCELLED') {
        // Peer initiated — it already wrote the terminal state and owns doc
        // cleanup. Tear down locally without writing state back.
        endCall(remoteInitiated: true);
      }
    });
  }

  Future<void> _updateNotification() async {
    if (_callType != null) {
      await CallNotifications.showOngoingCall(
        callType: _callType!,
        peerName: _peerName,
        statusText: _statusText,
      );
    }
  }

  void setAudioEnabled(bool enabled) => _webRtcClient?.setAudioEnabled(enabled);
  void setVideoEnabled(bool enabled) => _webRtcClient?.setVideoEnabled(enabled);

  /// Loudspeaker on/off. No-op on web (browser routes audio itself).
  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (e) {
      debugPrint('OngoingCallManager: setSpeakerphoneOn failed: $e');
    }
  }

  Future<void> switchCamera() async => _webRtcClient?.switchCamera();

  Future<void> attachLocalPreview(RTCVideoRenderer renderer) async =>
      _webRtcClient?.attachLocalPreview(renderer);

  void detachLocalPreview(RTCVideoRenderer renderer) =>
      _webRtcClient?.detachLocalPreview(renderer);

  Future<void> attachRemotePreview(RTCVideoRenderer renderer) async =>
      _webRtcClient?.attachRemotePreview(renderer);

  void detachRemotePreview(RTCVideoRenderer renderer) =>
      _webRtcClient?.detachRemotePreview(renderer);

  /// [remoteInitiated] is true when we're ending because the peer's terminal
  /// state (or the doc's removal) was observed — in that case we must NOT
  /// write state back (the peer owns the doc and is deleting it; a late
  /// write would resurrect it) and only tear down locally.
  Future<void> endCall({bool remoteInitiated = false}) async {
    if (_hasEnded) return;
    _hasEnded = true;

    _monitor?.cancel();
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    unawaited(CallForegroundService.stop());

    final endingCallId = _callId;

    if (endingCallId != null) {
      // Drop our onDisconnect fallback either way — we're ending cleanly.
      await _signaling.disarmDisconnectEnd(endingCallId);

      if (remoteInitiated) {
        // The peer wrote the terminal state and owns cleanup. Don't write
        // state back (a late write could resurrect the node it just
        // deleted), but still schedule a delete on a longer delay as a
        // fallback in case the peer died before its own cleanup ran.
        _signaling.scheduleCleanup(endingCallId,
            delay: const Duration(seconds: 20));
      } else {
        // Tell the other side FIRST, and AWAIT it, before tearing down — on
        // a phone the process can die right after the screen pops, so the
        // RTDB write must leave the device before teardown or the peer's
        // call just hangs. endCall() writes ENDED, then schedules the
        // `calls/{id}` node (state + offer/answer/ICE) for removal once the
        // peer has had a chance to see the transition.
        await _signaling.endCall(endingCallId);
      }
    }

    _stateSub?.cancel();
    _offerSub?.cancel();
    _answerSub?.cancel();
    _callerCandidatesSub?.cancel();
    _calleeCandidatesSub?.cancel();

    _webRtcClient?.endCall();
    _webRtcClient = null;

    CallNotifications.cancelOngoing();

    _callId = null;
    _isInitialized = false;
  }
}