import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../calls/call_platform.dart';
import '../calls/ongoing_call_manager.dart';

class OngoingCallScreen extends StatefulWidget {
  final String callId;
  final String callType;
  final bool isCaller;
  final String peerName;

  const OngoingCallScreen({
    super.key,
    required this.callId,
    required this.callType,
    required this.isCaller,
    required this.peerName,
  });

  @override
  State<OngoingCallScreen> createState() => _OngoingCallScreenState();
}

class _OngoingCallScreenState extends State<OngoingCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _isMuted = false;
  // Matches the native default OngoingCallManager sets at call start
  // (setSpeakerphoneOn(true)) — audio and video calls both start on speaker.
  bool _isSpeakerOn = true;
  bool _isVideoEnabled = true;
  String _statusText = 'Connecting…';
  MediaStreamTrack? _remoteTrack;

  // Web-only bug workaround: flutter_webrtc's web RTCVideoView looks up its
  // target <video> DOM element ONCE, in its own initState(), and never
  // re-queries it — if that element doesn't exist yet at that exact moment,
  // the video never renders again for that widget's lifetime, full stop.
  // _localRenderer/_remoteRenderer.initialize() below run sequentially, and
  // this screen's very first build() (which mounts BOTH RTCVideoViews at
  // once) happens between those two awaits — so _remoteRenderer's element
  // never existed yet when its RTCVideoView first mounted, and the remote
  // side of every video call was permanently blank on web. _localRenderer
  // happened to already exist by then (it's the first of the two awaits),
  // which is why only the local/self preview ever worked. Don't mount
  // either RTCVideoView until both renderers are fully initialized.
  bool _renderersReady = false;

  StreamSubscription<String>? _statusSub;
  StreamSubscription<MediaStreamTrack>? _trackSub;
  StreamSubscription<DatabaseEvent>? _remoteStateSub;

  @override
  void initState() {
    super.initState();
    _init();
    _watchRemoteCallState();
  }

  // OngoingCallManager._listenForRemoteHangup() already tears down the
  // WebRTC connection when the remote party ends the call, but it has no
  // way to reach this widget — nothing was ever popping this screen off
  // the Navigator when the OTHER side hung up. OutgoingCallScreen and
  // IncomingCallScreen both already watch RTDB state directly for this
  // same reason; this screen was the one missing it.
  void _watchRemoteCallState() {
    _remoteStateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(widget.callId)
        .child('state')
        .onValue
        .listen((event) {
      final state = event.snapshot.value as String?;
      if (state == 'ENDED' ||
          state == 'DECLINED' ||
          state == 'MISSED' ||
          state == 'CANCELLED') {
        OngoingCallManager.instance.endCall();
        if (mounted) Navigator.pop(context);
      }
    });
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() => _renderersReady = true);

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required')),
        );
        Navigator.pop(context);
      }
      return;
    }

    bool cameraGranted = false;
    if (widget.callType.toLowerCase() == 'video') {
      final cam = await Permission.camera.request();
      cameraGranted = cam.isGranted;
    }

    final manager = OngoingCallManager.instance;

    _statusSub = manager.statusStream.listen((status) {
      if (mounted) setState(() => _statusText = status);
    });

    _trackSub = manager.remoteTrackStream.listen((track) {
      if (mounted) setState(() => _remoteTrack = track);
    });

    await manager.startCall(
      callId: widget.callId,
      callType: widget.callType,
      isCaller: widget.isCaller,
      peerName: widget.peerName,
      cameraGranted: cameraGranted,
    );

    await manager.attachLocalPreview(_localRenderer);
    await manager.attachRemotePreview(_remoteRenderer);
  }

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    OngoingCallManager.instance.setAudioEnabled(!_isMuted);
  }

  void _toggleSpeaker() {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    OngoingCallManager.instance.setSpeakerphoneOn(_isSpeakerOn);
  }

  void _toggleVideo() {
    setState(() => _isVideoEnabled = !_isVideoEnabled);
    OngoingCallManager.instance.setVideoEnabled(_isVideoEnabled);
  }

  Future<void> _switchCamera() async {
    await OngoingCallManager.instance.switchCamera();
  }

  void _endCall() {
    OngoingCallManager.instance.endCall();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _trackSub?.cancel();
    _remoteStateSub?.cancel();
    OngoingCallManager.instance.detachLocalPreview(_localRenderer);
    OngoingCallManager.instance.detachRemotePreview(_remoteRenderer);
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType.toLowerCase() == 'video';

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) {
          // Send the app to background instead of ending the call — the
          // call and its foreground service stay alive underneath. Only
          // the explicit End Call button should ever end the call.
          CallPlatform.moveTaskToBack();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Remote video (full screen)
            if (isVideo && _renderersReady)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),

            // Local video (picture-in-picture)
            if (isVideo && _isVideoEnabled && _renderersReady)
              Positioned(
                top: 48,
                right: 16,
                child: SizedBox(
                  width: 120,
                  height: 160,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(
                      _localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),

            // Controls overlay — SafeArea'd (unlike the full-bleed video
            // above) so the end-call button isn't sitting in the gesture-nav
            // zone on edge-to-edge Android 15+ devices; the remote video
            // itself is meant to stay full-bleed behind it.
            SafeArea(
              child: Column(
                children: [
                  const Spacer(),
                  Text(
                    _statusText,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (isVideo) ...[
                        _ControlButton(
                          icon: _isVideoEnabled ? Icons.videocam : Icons.videocam_off,
                          onTap: _toggleVideo,
                        ),
                        _ControlButton(
                          icon: Icons.cameraswitch,
                          onTap: _switchCamera,
                        ),
                      ],
                      _ControlButton(
                        icon: _isMuted ? Icons.mic_off : Icons.mic,
                        onTap: _toggleMute,
                      ),
                      _ControlButton(
                        icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                        onTap: _toggleSpeaker,
                      ),
                      _ControlButton(
                        icon: Icons.call_end,
                        color: const Color(0xFFE53935),
                        onTap: _endCall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color ?? Colors.white, size: 28),
      ),
    );
  }
}