import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../calls/call_connection_monitor.dart';
import '../calls/call_signaling_repository.dart';
import '../calls/web_rtc_client.dart';
import 'call_foreground_service.dart';

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

  /// Starts (or, on a repeat call for the same in-progress call, simply
  /// re-attaches to) the call.
  ///
  /// IMPORTANT: this is now called TWICE in the caller's flow by design —
  /// once from OutgoingCallScreen the moment the caller presses "call"
  /// (before the callee has answered), and again from OngoingCallScreen
  /// right after acceptance. The `_isInitialized` guard below makes the
  /// second call a no-op re-attach instead of a second getUserMedia() /
  /// second peer connection. This is what lets the caller's local preview
  /// and the real WebRTC stream be the exact same MediaStream.
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
    _statusText = 'Connecting…';

    await CallForegroundService.start(
      title: callType == 'video' ? 'Video call' : 'Voice call',
      text: '$peerName • $_statusText',
    );

    _monitor = CallConnectionMonitor(
      // 30s was too tight for cross-network calls (e.g. Android cellular
      // <-> web Wi-Fi) where ICE/TURN negotiation can legitimately take
      // longer than that, ending the call before it ever finished
      // connecting. 60s gives real-world NAT traversal enough room.
      timeoutMs: 60000,
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

    _webRtcClient = WebRtcClient(
      onLocalIceCandidate: (candidate) {
        if (_callId != null && _isCaller != null) {
          _signaling.sendIceCandidate(_callId!, _isCaller!, candidate);
        }
      },
      onRemoteVideoTrack: (track) {
        _remoteTrackController.add(track);
      },
      onConnectionStateChanged: (state) {
        _monitor?.onPeerConnectionStateChange(state);
        _statusText = switch (state) {
          RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'Connected',
          RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'Connection failed',
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'Reconnecting…',
          _ => 'Connecting…',
        };
        _statusController.add(_statusText);
        _updateNotification();
      },
    );

    await _webRtcClient!.initFactory();

    final localStream = await _webRtcClient!.setupLocalMedia(
      isVideo && cameraGranted,
    );

    final iceServers = await _webRtcClient!.fetchIceServers();
    await _webRtcClient!.setupPeerConnection(localStream, iceServers);

    // Route audio to the loudspeaker from the moment the call connects —
    // WebRTC's default native audio route on Android is the tiny earpiece
    // speaker, which reads as "muted" unless the phone is held to the ear.
    // OngoingCallScreen's toggle previously only flipped a UI icon; nothing
    // ever called the actual native routing API.
    _webRtcClient!.setSpeakerphoneOn(true);

    _listenForRemoteHangup();
    if (_isCaller == true) {
      await _startAsCaller();
    } else {
      await _startAsCallee();
    }
  }

  Future<void> _startAsCaller() async {
    final callId = _callId!;
    final sdp = await _webRtcClient!.createOffer();
    await _signaling.sendOffer(callId, sdp);

    _answerSub = _signaling.observeAnswer(callId, (answerSdp) {
      _webRtcClient!.setRemoteAnswer(answerSdp);
    });

    _calleeCandidatesSub = _signaling.observeRemoteIceCandidates(
      callId,
      true,
          (candidate) async => _webRtcClient!.addRemoteIceCandidate(candidate),
    );
  }

  Future<void> _startAsCallee() async {
    final callId = _callId!;

    _offerSub = _signaling.observeOffer(callId, (offerSdp) {
      _webRtcClient!.setRemoteOffer(offerSdp, onSetSuccess: () async {
        final answerSdp = await _webRtcClient!.createAnswer();
        await _signaling.sendAnswer(callId, answerSdp);
      });
    });

    _callerCandidatesSub = _signaling.observeRemoteIceCandidates(
      callId,
      false,
          (candidate) async => _webRtcClient!.addRemoteIceCandidate(candidate),
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
      if (state == 'ENDED' || state == 'DECLINED' || state == 'MISSED') {
        endCall();
      }
    });
  }

  Future<void> _updateNotification() async {
    if (_callType != null) {
      await CallForegroundService.update(
        title: _callType == 'video' ? 'Video call' : 'Voice call',
        text: '$_peerName • $_statusText',
      );
    }
  }

  void setAudioEnabled(bool enabled) => _webRtcClient?.setAudioEnabled(enabled);
  void setVideoEnabled(bool enabled) => _webRtcClient?.setVideoEnabled(enabled);
  void setSpeakerphoneOn(bool enabled) => _webRtcClient?.setSpeakerphoneOn(enabled);

  Future<void> switchCamera() async => _webRtcClient?.switchCamera();

  Future<void> attachLocalPreview(RTCVideoRenderer renderer) async =>
      _webRtcClient?.attachLocalPreview(renderer);

  void detachLocalPreview(RTCVideoRenderer renderer) =>
      _webRtcClient?.detachLocalPreview(renderer);

  Future<void> attachRemotePreview(RTCVideoRenderer renderer) async =>
      _webRtcClient?.attachRemotePreview(renderer);

  void detachRemotePreview(RTCVideoRenderer renderer) =>
      _webRtcClient?.detachRemotePreview(renderer);

  void endCall() {
    if (_hasEnded) return;
    _hasEnded = true;

    _monitor?.cancel();

    try {
      if (_callId != null) {
        FirebaseDatabase.instance.ref('calls').child(_callId!).child('state').set('ENDED');
      }
    } catch (_) {}

    _stateSub?.cancel();
    _offerSub?.cancel();
    _answerSub?.cancel();
    _callerCandidatesSub?.cancel();
    _calleeCandidatesSub?.cancel();

    _webRtcClient?.endCall();
    _webRtcClient = null;

    CallForegroundService.stop();

    _callId = null;
    _isInitialized = false;
  }
}