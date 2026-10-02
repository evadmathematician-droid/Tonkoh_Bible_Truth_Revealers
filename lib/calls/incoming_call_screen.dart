import 'dart:typed_data';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import '../calls/ongoing_call_screen.dart';
import '../navigation/call_navigator.dart';
import '../util/base64_image_cache.dart';
import 'call_signaling_repository.dart';
import 'incoming_call_manager.dart';
import 'dart:async';


class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerPhoto;
  final String chatId;
  final String callType;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerId,
    required this.callerName,
    this.callerPhoto = '',
    required this.chatId,
    required this.callType,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<DatabaseEvent>? _stateSub;
  final CallSignalingRepository _signaling = CallSignalingRepository();

  @override
  void initState() {
    super.initState();
    _watchCallState();
  }

  void _watchCallState() {
    _stateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(widget.callId)
        .child('state')
        .onValue
        .listen((event) {
      final state = event.snapshot.value as String?;
      // Caller cancelled / hung up / the call doc was removed while we were
      // still ringing — leave the ringing screen. (Attaches while state is
      // RINGING, so the first immediate event never matches.)
      if (state == null ||
          state == 'ENDED' ||
          state == 'MISSED' ||
          state == 'DECLINED' ||
          state == 'CANCELLED') {
        if (mounted) CallNavigator.leaveCall();
      }
    });
  }

  Uint8List? _decodePhoto() => Base64ImageCache.decode(widget.callerPhoto);

  Future<void> _accept() async {
    // Route through the manager so its ringing timers / listeners / the
    // onDisconnect fallback are all torn down (otherwise its 45 s timer
    // later declines this already-accepted call). It writes ACCEPTED; we
    // also write it directly as a fallback in case the manager's state was
    // already cleared.
    IncomingCallManager.instance.acceptCall();
    await FirebaseDatabase.instance
        .ref('calls')
        .child(widget.callId)
        .child('state')
        .set('ACCEPTED');

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => OngoingCallScreen(
          callId: widget.callId,
          callType: widget.callType,
          isCaller: false,
          peerName: widget.callerName,
        ),
      ),
    );
  }

  Future<void> _decline() async {
    // Manager tears down its ringing timers / listeners; the direct call is
    // the authoritative signal in case the manager's state was already
    // cleared (both write DECLINED for the same id — idempotent).
    IncomingCallManager.instance.declineCall();
    await _signaling.endCall(widget.callId, state: 'DECLINED');
    if (mounted) CallNavigator.leaveCall();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType.toLowerCase() == 'video';
    final photoBytes = _decodePhoto();

    return Scaffold(
      backgroundColor: const Color(0xFF0B1F5C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                children: [
                  const SizedBox(height: 64),
                  Text(
                    isVideo ? 'Incoming video call' : 'Incoming call',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ClipOval(
                    child: Container(
                      width: 120,
                      height: 120,
                      color: Colors.white.withValues(alpha: 0.15),
                      child: photoBytes != null
                          ? Image.memory(
                              photoBytes,
                              fit: BoxFit.cover,
                              cacheWidth:
                                  (120 * MediaQuery.devicePixelRatioOf(context))
                                      .ceil(),
                            )
                          : const Icon(Icons.person, size: 56, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.callerName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(
                    icon: Icons.call_end,
                    color: const Color(0xFFE53935),
                    label: 'Decline',
                    onTap: _decline,
                  ),
                  _ActionButton(
                    icon: Icons.call,
                    color: const Color(0xFF43A047),
                    label: 'Accept',
                    onTap: _accept,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}