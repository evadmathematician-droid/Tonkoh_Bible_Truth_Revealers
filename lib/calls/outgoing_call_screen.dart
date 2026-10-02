import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ringback_manager.dart';
import 'call_signaling_repository.dart';
import 'missed_call.dart';
import '../calls/ongoing_call_screen.dart';
import '../navigation/call_navigator.dart';

class OutgoingCallScreen extends StatefulWidget {
  final String callId;
  final String callerUid;
  final String callerName;
  final String calleeUid;
  final String calleeName;
  final String callType;

  const OutgoingCallScreen({
    super.key,
    required this.callId,
    required this.callerUid,
    required this.callerName,
    required this.calleeUid,
    required this.calleeName,
    required this.callType,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  final RingbackManager _ringback = RingbackManager();
  final CallSignalingRepository _signaling = CallSignalingRepository();
  StreamSubscription<DatabaseEvent>? _stateSub;
  Timer? _noAnswerTimer;
  bool _wasAccepted = false;
  bool _missedLogged = false;

  RTCVideoRenderer? _previewRenderer;
  MediaStream? _previewStream;

  @override
  void initState() {
    super.initState();
    _ringback.start();
    // If we're killed / lose connectivity while ringing, let Firebase end
    // the call so the callee stops ringing instead of hanging.
    _signaling.armDisconnectEnd(widget.callId);
    // Callee never answers *and* never rejects (e.g. offline) — don't ring
    // forever. The callee has its own 45 s MISSED timer; this is the caller
    // side's equivalent.
    _noAnswerTimer = Timer(const Duration(seconds: 45), () {
      if (mounted) _cancelCall();
    });
    _initCameraPreview();
    _watchCallState();
  }

  Future<void> _initCameraPreview() async {
    if (widget.callType.toLowerCase() != 'video') return;

    final status = await Permission.camera.request();
    if (!status.isGranted) return;

    _previewStream = await navigator.mediaDevices.getUserMedia({
      'video': {'facingMode': 'user'},
      'audio': false,
    });

    _previewRenderer = RTCVideoRenderer();
    await _previewRenderer!.initialize();
    _previewRenderer!.srcObject = _previewStream;

    if (mounted) setState(() {});
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
        case 'MISSED':
          // Callee's ring timed out with no answer.
          _logMissed();
          _finish();
          break;
        case 'DECLINED':
        case 'ENDED':
        case 'CANCELLED':
        case null: // call doc removed out from under us
          _finish();
          break;
      }
    });
  }

  /// Log the unanswered call as a "Missed call" entry on both sides. Safe to
  /// call more than once — guarded, and the underlying writes are keyed by
  /// call id.
  void _logMissed() {
    if (_wasAccepted || _missedLogged) return;
    _missedLogged = true;
    unawaited(MissedCallLog.recordLocal(
      callId: widget.callId,
      selfUid: widget.callerUid,
      otherUid: widget.calleeUid,
      otherName: widget.calleeName,
      callType: widget.callType,
      incoming: false,
    ));
    unawaited(MissedCallLog.relayToPeer(
      callId: widget.callId,
      callerUid: widget.callerUid,
      callerName: widget.callerName,
      calleeUid: widget.calleeUid,
      callType: widget.callType,
    ));
  }

  void _onCallAccepted() {
    _wasAccepted = true;
    _noAnswerTimer?.cancel();
    _ringback.stop();
    // The ongoing-call manager arms its own onDisconnect for the live call.
    _signaling.disarmDisconnectEnd(widget.callId);
    _releasePreview();
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

  void _cancelCall() {
    _noAnswerTimer?.cancel();
    // Caller gave up before the callee answered (end button or 45s no-answer
    // timer) — that's a missed call for the callee.
    _logMissed();
    // Tell the callee (fire-and-forget): `endCall()` issues the
    // `set('ENDED')` synchronously before its first await, so it's on the
    // wire before _finish() cancels our onDisconnect. Offline it's queued
    // and flushes on reconnect.
    unawaited(_signaling.endCall(widget.callId));
    // Local teardown must NOT sit behind that RTDB write — `endCall()`
    // awaits an ack that never comes while offline, which is exactly why
    // the ringback kept playing after a hang-up. _finish() stops the tone,
    // releases the preview and pops synchronously.
    _finish();
  }

  void _finish() {
    _noAnswerTimer?.cancel();
    _ringback.stop();
    // We're leaving the ringing screen without having initiated the end
    // (peer declined / accepted elsewhere / doc gone) — drop our
    // onDisconnect fallback so it can't fire later.
    _signaling.disarmDisconnectEnd(widget.callId);
    _releasePreview();
    if (mounted) CallNavigator.leaveCall();
  }

  void _releasePreview() {
    _previewRenderer?.dispose();
    _previewRenderer = null;
    _previewStream?.getTracks().forEach((t) => t.stop());
    _previewStream?.dispose();
    _previewStream = null;
  }

  @override
  void dispose() {
    _noAnswerTimer?.cancel();
    _ringback.dispose();
    _stateSub?.cancel();
    _releasePreview();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType.toLowerCase() == 'video';
    final hasPreview = _previewRenderer != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1F5C),
      body: SafeArea(
        child: Stack(
          children: [
            if (isVideo && hasPreview)
              Positioned.fill(
                child: RTCVideoView(
                  _previewRenderer!,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            if (isVideo && hasPreview)
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
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
                          color: Colors.white.withValues(alpha: 0.8),
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
                          color: Colors.white.withValues(alpha: 0.7),
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