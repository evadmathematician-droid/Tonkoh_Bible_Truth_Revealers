import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../calls/call_models.dart';

class WebRtcClient {
  static const String _tag = 'WebRtcClient';
  static const String _turnCredsEndpoint =
      'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev';

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaStreamTrack? _localVideoTrack;
  MediaStreamTrack? _localAudioTrack;

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;

  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;
  bool _hasEnded = false;

  final void Function(IceCandidateModel candidate) onLocalIceCandidate;
  final void Function(MediaStreamTrack track) onRemoteVideoTrack;
  final void Function(RTCPeerConnectionState state) onConnectionStateChanged;

  WebRtcClient({
    required this.onLocalIceCandidate,
    required this.onRemoteVideoTrack,
    required this.onConnectionStateChanged,
  });

  Future<List<Map<String, dynamic>>> fetchIceServers() async {
    final dio = Dio();
    try {
      final response = await dio.post(
        _turnCredsEndpoint,
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data is Map ? response.data : jsonDecode(response.data);
        final iceServersObj = data['iceServers'];
        final urls = List<String>.from(iceServersObj['urls']);
        final username = iceServersObj['username'] ?? '';
        final credential = iceServersObj['credential'] ?? '';

        final servers = <Map<String, dynamic>>[];
        for (final url in urls) {
          final server = <String, dynamic>{'urls': url};
          if (url.startsWith('turn:') || url.startsWith('turns:')) {
            server['username'] = username;
            server['credential'] = credential;
          }
          servers.add(server);
        }
        debugPrint('$_tag: Fetched ${servers.length} ICE servers from Worker');
        return servers;
      }
    } catch (e) {
      debugPrint('$_tag: TURN creds fetch exception: $e');
    }
    return _fallbackStunOnly();
  }

  List<Map<String, dynamic>> _fallbackStunOnly() => [
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ];

  /// No-op in Flutter — the plugin initializes internally. Kept to match the
  /// Kotlin API surface so callers don't need to change their flow.
  Future<void> initFactory() async {
    // flutter_webrtc handles factory initialization automatically.
  }

  Future<MediaStream> setupLocalMedia(bool isVideo, {RTCVideoRenderer? localRenderer}) async {
    final videoConstraints = isVideo
        ? {
      'width': {'ideal': 1280},
      'height': {'ideal': 720},
      'frameRate': {'ideal': 30},
      'facingMode': 'user',
    }
        : false;

    final constraints = <String, dynamic>{
      'audio': true,
      'video': videoConstraints,
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    } catch (e) {
      debugPrint('$_tag: getUserMedia failed with ideal video constraints ($e)');
      if (isVideo) {
        // Retry with no constraints at all — let the browser pick whatever the camera supports.
        try {
          _localStream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': true,
          });
        } catch (e2) {
          debugPrint('$_tag: getUserMedia retry failed ($e2), falling back to audio-only');
          _localStream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': false,
          });
        }
      } else {
        rethrow;
      }
    }

    _localAudioTrack = _localStream!.getAudioTracks().firstOrNull;
    _localAudioTrack?.enabled = true;

    if (isVideo) {
      _localVideoTrack = _localStream!.getVideoTracks().firstOrNull;
      if (localRenderer != null) {
        await attachLocalPreview(localRenderer);
      }
    }

    return _localStream!;
  }

  Future<void> attachLocalPreview(RTCVideoRenderer renderer) async {
    await renderer.initialize();
    renderer.srcObject = _localStream;
    _localRenderer = renderer;
  }

  void detachLocalPreview(RTCVideoRenderer renderer) {
    if (_localRenderer == renderer) {
      renderer.srcObject = null;
      _localRenderer = null;
    }
  }

  Future<void> attachRemotePreview(RTCVideoRenderer renderer) async {
    await renderer.initialize();
    _remoteRenderer = renderer;
    // onTrack (below) only fires once, whenever the remote peer's media
    // actually arrives — which can happen before this renderer is attached
    // (e.g. the callee's ICE/DTLS handshake completing while OngoingCallScreen
    // is still mid-permission-request). Without this, a renderer attached
    // after that point would sit with a null srcObject forever: nothing
    // tells it the remote stream already exists. Sync eagerly here so
    // attachment order can never cause a missed remote video bind.
    if (_remoteStream != null) {
      renderer.srcObject = _remoteStream;
    }
  }

  void detachRemotePreview(RTCVideoRenderer renderer) {
    if (_remoteRenderer == renderer) {
      renderer.srcObject = null;
      _remoteRenderer = null;
    }
  }

  void setSpeakerphoneOn(bool enabled) {
    try {
      Helper.setSpeakerphoneOn(enabled);
    } catch (e) {
      debugPrint('$_tag: setSpeakerphoneOn failed: $e');
    }
  }

  Future<void> setupPeerConnection(MediaStream localStream, List<Map<String, dynamic>> iceServers) async {
    final config = <String, dynamic>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportsType': 'all',
    };

    _peerConnection = await createPeerConnection(config, {});

    _peerConnection!.onIceCandidate = (candidate) {
      onLocalIceCandidate(IceCandidateModel(
        sdpMid: candidate.sdpMid ?? '',
        sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
        candidate: candidate.candidate ?? '',
      ));
    };

    _peerConnection!.onTrack = (event) {
      final track = event.track;
      if (track == null) return;

      debugPrint('$_tag: onTrack fired: kind=${track.kind} id=${track.id}');

      if (track.kind == 'video') {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
          _remoteRenderer?.srcObject = _remoteStream;
        }
        onRemoteVideoTrack(track);
      } else if (track.kind == 'audio') {
        track.enabled = true;
      }
    };

    _peerConnection!.onConnectionState = (state) {
      onConnectionStateChanged(state);
    };

    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('$_tag: ICE connection state: $state');
    };

    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('$_tag: ICE gathering state: $state');
    };

    for (final track in localStream.getTracks()) {
      await _peerConnection!.addTrack(track, localStream);
    }
  }

  Future<String> createOffer() async {
    final offer = await _peerConnection!.createOffer({
      'mandatory': {},
      'optional': [],
    });
    await _peerConnection!.setLocalDescription(offer);
    return offer.sdp!;
  }

  Future<String> createAnswer() async {
    final answer = await _peerConnection!.createAnswer({
      'mandatory': {},
      'optional': [],
    });
    await _peerConnection!.setLocalDescription(answer);
    return answer.sdp!;
  }

  Future<void> setRemoteOffer(String sdp, {VoidCallback? onSetSuccess}) async {
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    await _onRemoteDescriptionApplied();
    onSetSuccess?.call();
  }

  Future<void> setRemoteAnswer(String sdp) async {
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    await _onRemoteDescriptionApplied();
  }

  Future<void> _onRemoteDescriptionApplied() async {
    _remoteDescriptionSet = true;
    for (final candidate in _pendingRemoteCandidates) {
      await _peerConnection?.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  // Made async: addCandidate() is itself asynchronous. The previous
  // synchronous signature silently fired-and-forgot that Future, which
  // made ICE-candidate errors invisible and made the signaling flow harder
  // to reason about/await from OngoingCallManager.
  Future<void> addRemoteIceCandidate(IceCandidateModel model) async {
    final candidate = RTCIceCandidate(
      model.candidate,
      model.sdpMid,
      model.sdpMLineIndex,
    );
    if (_remoteDescriptionSet) {
      await _peerConnection?.addCandidate(candidate);
    } else {
      _pendingRemoteCandidates.add(candidate);
    }
  }

  void setAudioEnabled(bool enabled) {
    _localAudioTrack?.enabled = enabled;
  }

  void setVideoEnabled(bool enabled) {
    _localVideoTrack?.enabled = enabled;
  }

  Future<void> switchCamera() async {
    if (_localVideoTrack != null) {
      await Helper.switchCamera(_localVideoTrack!);
    }
  }

  void endCall() {
    if (_hasEnded) return;
    _hasEnded = true;

    _pendingRemoteCandidates.clear();

    try {
      _localRenderer?.srcObject = null;
    } catch (_) {}
    try {
      _remoteRenderer?.srcObject = null;
    } catch (_) {}
    _localRenderer = null;
    _remoteRenderer = null;
    _remoteStream = null;

    try {
      _peerConnection?.close();
    } catch (_) {}

    try {
      _localVideoTrack?.stop();
    } catch (_) {}
    try {
      _localAudioTrack?.stop();
    } catch (_) {}

    _localStream?.getTracks().forEach((t) => t.stop());
    try {
      _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    _localVideoTrack = null;
    _localAudioTrack = null;

    _peerConnection?.dispose();
    _peerConnection = null;
  }
}