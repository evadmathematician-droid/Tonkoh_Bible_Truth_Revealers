import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ringback_manager.dart';
import '../calls/ongoing_call_manager.dart';
import '../calls/ongoing_call_screen.dart';

class OutgoingCallScreen extends StatefulWidget {
  final String callId;
  final String calleeName;
  final String callType;

  const OutgoingCallScreen({
    super.key,
    required this.callId,
    required this.calleeName,
    required this.callType,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  final RingbackManager _ringback = RingbackManager();
  StreamSubscription<DatabaseEvent>? _stateSub;

  // This renderer shows the SAME stream that will be used for the real
  // WebRTC peer connection — there is no separate preview-only stream
  // anymore. OngoingCallManager owns the single MediaStream from the
  // moment the call starts ringing until it ends.
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _rendererReady = false;
  bool _callStarted = false;

  @override
  void initState() {
    super.initState();
    _ringback.start();
    _startCall();
    _watchCallState();
  }

  Future<void> _startCall() async {
    // Microphone is always required; camera only for video calls.
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
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
      final camStatus = await Permission.camera.request();
      cameraGranted = camStatus.isGranted;
    }

    await _localRenderer.initialize();

    // This is the ONE place local media gets acquired for the caller side.
    // It creates the WebRtcClient, calls getUserMedia once, sets up the
    // peer connection, and sends the offer — all while the callee is still
    // just seeing "RINGING". When OngoingCallScreen later calls startCall()
    // again after acceptance, OngoingCallManager's _isInitialized guard
    // makes that call a no-op re-attach instead of a second getUserMedia().
    await OngoingCallManager.instance.startCall(
      callId: widget.callId,
      callType: widget.callType,
      isCaller: true,
      peerName: widget.calleeName,
      cameraGranted: cameraGranted,
    );

    await OngoingCallManager.instance.attachLocalPreview(_localRenderer);

    _callStarted = true;
    if (mounted) setState(() => _rendererReady = true);
  }

  void _watchCallState() {
    _stateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(widget.callId)
        .child('state')
        .onValue
        .listen((event) {
      final state = event.snapshot.value as String?;
      switch (state) {
        case 'ACCEPTED':
          _onCallAccepted();
          break;
        case 'DECLINED':
        case 'ENDED':
        case 'MISSED':
          _finish(alreadyEnded: true);
          break;
      }
    });
  }

  void _onCallAccepted() {
    _ringback.stop();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => OngoingCallScreen(
          callId: widget.callId,
          callType: widget.callType,
          isCaller: true,
          peerName: widget.calleeName,
        ),
      ),
    );
  }

  Future<void> _cancelCall() async {
    // endCall() already sets Firebase state to 'ENDED' and tears down the
    // WebRtcClient/local stream — no separate Firebase write needed here.
    OngoingCallManager.instance.endCall();
    _finish(alreadyEnded: true);
  }

  void _finish({bool alreadyEnded = false}) {
    _ringback.stop();
    if (!alreadyEnded && _callStarted) {
      // Safety net: if we got here some other way (e.g. remote hangup
      // reached us before we called endCall ourselves), make sure the
      // manager is still torn down.
      OngoingCallManager.instance.endCall();
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ringback.stop();
    _stateSub?.cancel();
    OngoingCallManager.instance.detachLocalPreview(_localRenderer);
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType.toLowerCase() == 'video';
    final hasPreview = isVideo && _rendererReady;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1F5C),
      body: SafeArea(
        child: Stack(
          children: [
            if (hasPreview)
              Positioned.fill(
                child: RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            if (hasPreview)
              Positioned.fill(
                child: Container(color: Colors.black.withOpacity(0.45)),
              ),
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    children: [
                      const SizedBox(height: 64),
                      Text(
                        isVideo ? 'Outgoing video call' : 'Outgoing call',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        widget.calleeName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Ringing…',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  Center(
                    child: InkWell(
                      onTap: _cancelCall,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE53935),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.call_end,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}