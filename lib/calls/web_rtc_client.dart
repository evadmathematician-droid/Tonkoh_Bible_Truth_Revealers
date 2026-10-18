import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../calls/call_models.dart';
import '../config/worker_api.dart';



class WebRtcClient {
  static const String _tag = 'WebRtcClient';
  static const String _turnCredsEndpoint = WorkerApi.turnCredentialsUrl;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStreamTrack? _localVideoTrack;
  MediaStreamTrack? _localAudioTrack;

  /// The remote media stream, kept so it can be (re)attached to the remote
  /// renderer regardless of the order in which onTrack and attachRemotePreview
  /// happen. Mirrors the Android native client's `remoteVideoTrackRef`.
  MediaStream? _remoteStream;

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;

  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;
  // Set the instant a setRemote* call starts, so a replayed Firebase value
  // event can't kick off a second setRemoteDescription (which aborts
  // negotiation). Distinct from _remoteDescriptionSet, which only flips once
  // the description has actually applied and it's safe to add ICE candidates.
  bool _remoteDescriptionStarted = false;
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

    // ✅ Removed the two redundant, unguarded getUserMedia(constraints) calls
    // that used to sit here. They discarded the fallback-handled _localStream
    // from above and re-ran the original (possibly failing) constraints
    // outside any try/catch — on devices where the ideal video constraints
    // failed, this threw uncaught and killed setupLocalMedia entirely before
    // any peer connection or signaling could happen.

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
    _remoteRenderer = renderer;
    // The remote track may have already arrived (onTrack can fire before this
    // runs — e.g. the callee applies the caller's offer while the call screen
    // is still wiring up its renderers). If so, attach it now; otherwise
    // onTrack will attach it when it arrives.
    if (_remoteStream != null) {
      _remoteRenderer!.srcObject = _remoteStream;
    }
  }

  void detachRemotePreview(RTCVideoRenderer renderer) {
    if (_remoteRenderer == renderer) {
      renderer.srcObject = null;
      _remoteRenderer = null;
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

    _peerConnection!.onTrack = (event) async {
      final track = event.track;

      debugPrint('$_tag: onTrack fired: kind=${track.kind} id=${track.id} '
          'streams=${event.streams.length}');

      // Prefer the stream the remote peer bundled the track with. Fall back to
      // a synthesised stream when event.streams is empty — some peers/SDPs
      // deliver the track with no associated MediaStream, and the old code
      // silently dropped the remote video in that case (this was why web never
      // showed the Android peer's camera while Android showed web's fine).
      MediaStream? stream =
          event.streams.isNotEmpty ? event.streams.first : _remoteStream;
      stream ??= await createLocalMediaStream('remote');

      if (stream.getTrackById(track.id ?? '') == null) {
        await stream.addTrack(track);
      }
      _remoteStream = stream;

      // Attach now if the renderer is ready; otherwise attachRemotePreview()
      // will pick up _remoteStream when it runs.
      _remoteRenderer?.srcObject = _remoteStream;

      if (track.kind == 'video') {
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
    if (_remoteDescriptionStarted) return;
    _remoteDescriptionStarted = true;
    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
    } catch (e) {
      _remoteDescriptionStarted = false;
      debugPrint('$_tag: setRemoteOffer failed: $e');
      rethrow;
    }
    _remoteDescriptionSet = true;
    _flushPendingCandidates();
    onSetSuccess?.call();
  }

  Future<void> setRemoteAnswer(String sdp) async {
    if (_remoteDescriptionStarted) return;
    _remoteDescriptionStarted = true;
    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
    } catch (e) {
      _remoteDescriptionStarted = false;
      debugPrint('$_tag: setRemoteAnswer failed: $e');
      rethrow;
    }
    _remoteDescriptionSet = true;
    _flushPendingCandidates();
  }

  void _flushPendingCandidates() {
    for (final candidate in _pendingRemoteCandidates) {
      _peerConnection?.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  void addRemoteIceCandidate(IceCandidateModel model) {
    final candidate = RTCIceCandidate(
      model.candidate,
      model.sdpMid,
      model.sdpMLineIndex,
    );
    if (_remoteDescriptionSet) {
      _peerConnection?.addCandidate(candidate);
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

  /// Dumps a one-line snapshot of call quality (RTT, packet loss, bitrate,
  /// fps) to the log every few seconds during a call, so an intermittent
  /// freeze can be correlated with the network afterwards.
  Future<void> logCallStats() async {
    final pc = _peerConnection;
    if (pc == null || _hasEnded) return;
    try {
      final reports = await pc.getStats();
      for (final r in reports) {
        final v = r.values;
        switch (r.type) {
          case 'candidate-pair':
            if (v['state'] == 'succeeded' && v['nominated'] == true) {
              debugPrint('$_tag STATS pair rtt=${v['currentRoundTripTime']}s '
                  'availOutKbps=${v['availableOutgoingBitrate']} '
                  'bytesRecv=${v['bytesReceived']}');
            }
            break;
          case 'inbound-rtp':
            debugPrint('$_tag STATS in[${v['kind']}] '
                'lost=${v['packetsLost']} jitter=${v['jitter']} '
                'fps=${v['framesPerSecond']}');
            break;
          case 'outbound-rtp':
            debugPrint('$_tag STATS out[${v['kind']}] '
                'bytesSent=${v['bytesSent']} fps=${v['framesPerSecond']}');
            break;
        }
      }
    } catch (e) {
      debugPrint('$_tag: getStats failed: $e');
    }
  }

  /// Best-effort ICE restart. NOTE: on its own this only re-gathers
  /// candidates — a full recovery still needs a fresh offer/answer exchange,
  /// which the signaling layer here doesn't yet re-run. Left in as the hook
  /// for that follow-up; currently the recovery path just waits for ICE to
  /// self-heal, then ends the call cleanly.
  Future<void> restartIce() async {
    try {
      await _peerConnection?.restartIce();
    } catch (e) {
      debugPrint('$_tag: restartIce failed: $e');
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

    try {
      _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;

    _peerConnection?.dispose();
    _peerConnection = null;
  }
}