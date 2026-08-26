import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../calls/ongoing_call_screen.dart';
import 'ringback_manager.dart';
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
  // Android/iOS get their ring sound from the OS notification
  // (CallNotifications.showIncomingCall) before this screen ever opens.
  // Web has no such notification (flutter_local_notifications is a no-op
  // there), so this screen is the only place an incoming ring can come
  // from — gated to web to avoid a second, redundant tone on other
  // platforms.
  final RingbackManager? _ringtone = kIsWeb ? RingbackManager() : null;

  @override
  void initState() {
    super.initState();
    _ringtone?.start();
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
      if (state == 'ENDED' || state == 'MISSED' || state == 'DECLINED') {
        _ringtone?.stop();
        if (mounted) Navigator.pop(context);
      }
    });
  }

  Uint8List? _decodePhoto() {
    if (widget.callerPhoto.isEmpty) return null;
    try {
      return base64Decode(widget.callerPhoto);
    } catch (_) {
      return null;
    }
  }

  Future<void> _accept() async {
    _ringtone?.stop();

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
    _ringtone?.stop();

    await FirebaseDatabase.instance
        .ref('calls')
        .child(widget.callId)
        .child('state')
        .set('DECLINED');

    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ringtone?.stop();
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
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ClipOval(
                    child: Container(
                      width: 120,
                      height: 120,
                      color: Colors.white.withOpacity(0.15),
                      child: photoBytes != null
                          ? Image.memory(photoBytes, fit: BoxFit.cover)
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