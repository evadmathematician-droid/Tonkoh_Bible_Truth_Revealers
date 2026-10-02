import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../calls/ongoing_call_manager.dart';
import '../navigation/call_navigator.dart';

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
  bool _isSpeakerOn = false;
  bool _isVideoEnabled = true;
  bool _leaving = false;
  String _statusText = 'Connecting…';

  StreamSubscription<String>? _statusSub;
  StreamSubscription<MediaStreamTrack>? _trackSub;
  StreamSubscription<DatabaseEvent>? _stateSub;

  @override
  void initState() {
    super.initState();
    _watchCallState();
    _init();
  }

  /// The other side ending the call writes `state = ENDED` (also DECLINED /
  /// MISSED for edge cases). Without this listener the peer's WebRTC session
  /// closed but THIS screen just sat there looking connected — which is why
  /// hanging up on the phone left the web call "still connected".
  void _watchCallState() {
    _stateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(widget.callId)
        .child('state')
        .onValue
        .listen((event) {
      final state = event.snapshot.value as String?;
      if (state == null ||
          state == 'ENDED' ||
          state == 'DECLINED' ||
          state == 'MISSED' ||
          state == 'CANCELLED') {
        _leaveNow();
      }
    });
  }

  void _leaveNow() {
    if (_leaving) return;
    _leaving = true;
    // Triggered by observing the peer's terminal state / doc removal — the
    // peer owns the doc, so tear down locally without writing state back.
    OngoingCallManager.instance.endCall(remoteInitiated: true);
    _closeRoute();
  }

  /// Leaves the call UI and returns to the app home. Uses
  /// [CallNavigator.leaveCall] (popUntil-first) rather than a bare `pop()`
  /// so ending a call can never finish the task / "close the app".
  void _closeRoute() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) CallNavigator.leaveCall();
    });
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    final isVideo = widget.callType.toLowerCase() == 'video';

    // Request mic (and camera for a video call) together, in one call.
    // Requesting them one after another triggered the XOS/Infinix quirk
    // where the second dialog is auto-dismissed, so the phone ended up
    // WITHOUT camera permission and published no video track — which is
    // why the web peer never saw the phone's camera.
    final wanted = <Permission>[
      Permission.microphone,
      if (isVideo) Permission.camera,
    ];
    final results = await wanted.request();

    if (results[Permission.microphone]?.isGranted != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required')),
        );
        Navigator.pop(context);
      }
      return;
    }

    // Re-read the camera status directly (not just the request result) so a
    // grant that landed a beat late still counts.
    final cameraGranted = isVideo &&
        (results[Permission.camera]?.isGranted == true ||
            await Permission.camera.isGranted);

    final manager = OngoingCallManager.instance;

    _statusSub = manager.statusStream.listen((status) {
      if (mounted) setState(() => _statusText = status);
    });

    _trackSub = manager.remoteTrackStream.listen((_) {
      if (mounted) setState(() {});
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

    // Mic active by default on every call — the manager also enforces this,
    // but make the UI state agree.
    manager.setAudioEnabled(true);
    if (mounted) {
      setState(() {
        _isMuted = false;
        // Video → loudspeaker; voice → earpiece (WhatsApp-style). The
        // manager already applied the routing; this just matches the icon.
        _isSpeakerOn = isVideo;
      });
    }
  }

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    OngoingCallManager.instance.setAudioEnabled(!_isMuted);
  }

  void _toggleSpeaker() {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    OngoingCallManager.instance.setSpeaker(_isSpeakerOn);
  }

  void _toggleVideo() {
    setState(() => _isVideoEnabled = !_isVideoEnabled);
    OngoingCallManager.instance.setVideoEnabled(_isVideoEnabled);
  }

  Future<void> _switchCamera() async {
    await OngoingCallManager.instance.switchCamera();
  }

  Future<void> _endCall() async {
    if (_leaving) return;
    _leaving = true;
    // Await the manager so the "ENDED" write reaches Firebase before this
    // screen goes away.
    await OngoingCallManager.instance.endCall();
    if (mounted) _closeRoute();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _trackSub?.cancel();
    _stateSub?.cancel();
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
      // Never let the system back pop this route directly — it's on the root
      // navigator and popping the last route finishes the task ("app closes
      // on hang-up"). Back always routes through _endCall(), which writes
      // ENDED for the peer then returns to AuthGate via CallNavigator.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endCall();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Remote media. Video call → full-screen picture. Voice call →
            // the RTCVideoView is still mounted, just 1x1 and invisible,
            // because on web the renderer only plays the remote AUDIO track
            // while its <video> element is attached to the DOM. Leaving it
            // out entirely is why web voice calls had no sound.
            if (isVideo)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              SizedBox(
                width: 1,
                height: 1,
                child: RTCVideoView(_remoteRenderer),
              ),

            // Local video (picture-in-picture)
            if (isVideo && _isVideoEnabled)
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
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),

            // Controls overlay — SafeArea keeps the call buttons above the
            // gesture / navigation bar now that the screen draws edge-to-edge.
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
                          icon: _isVideoEnabled
                              ? Icons.videocam
                              : Icons.videocam_off,
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
                  const SizedBox(height: 48),
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
          color: Colors.white.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color ?? Colors.white, size: 28),
      ),
    );
  }
}
