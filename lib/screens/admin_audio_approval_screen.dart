import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:async';

import '../screens/auth/auth_manager.dart';
import '../screens/components/admin_pin_gate.dart';

class AdminAudioApprovalScreen extends StatefulWidget {
  const AdminAudioApprovalScreen({super.key});

  @override
  State<AdminAudioApprovalScreen> createState() => _AdminAudioApprovalScreenState();
}

class _AdminAudioApprovalScreenState extends State<AdminAudioApprovalScreen> {
  // GoRouter exposes '/adminApproval' directly (deep link / typed URL on
  // web), so this screen needs its own PIN check — it can't rely on only
  // ever being reached via AdminScreen's "Review Uploaded Audio" button.
  // Shares AuthManager.isAdminUnlockedThisSession with AdminScreen so
  // unlocking once covers both for the rest of the app session.
  bool get _unlocked => AuthManager.isAdminUnlockedThisSession;

  final List<Map<String, dynamic>> _pending = [];
  bool _loading = true;

  // Screen-local player — intentionally separate from GlobalAudioPlayer
  // (6c), so previewing a pending upload here doesn't interrupt or get
  // interrupted by whatever's playing in the main audio feed.
  AudioPlayer? _player;
  String? _playingUrl;
  bool _isPlaying = false;

  StreamSubscription<DatabaseEvent>? _sub;

  @override
  void initState() {
    super.initState();
    final ref = FirebaseDatabase.instance.ref('sermons').child('pending');
    _sub = ref.onValue.listen((event) {
      final value = event.snapshot.value;
      final list = <Map<String, dynamic>>[];
      if (value is Map) {
        value.forEach((key, child) {
          if (child is Map) {
            final item = Map<String, dynamic>.from(child);
            item['id'] = key;
            list.add(item);
          }
        });
      }
      setState(() {
        _pending
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    }, onError: (_) {
      setState(() => _loading = false);
    });
  }

  Future<void> _releasePlayer() async {
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
    setState(() {
      _playingUrl = null;
      _isPlaying = false;
    });
  }

  Future<void> _playAudio(String url) async {
    await _releasePlayer();
    try {
      final player = AudioPlayer();
      _player = player;
      player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          _releasePlayer();
        }
      });
      await player.setUrl(url);
      await player.play();
      setState(() {
        _playingUrl = url;
        _isPlaying = true;
      });
    } catch (_) {
      await _releasePlayer();
    }
  }

  Future<void> _pauseAudio() async {
    try {
      await _player?.pause();
      setState(() => _isPlaying = false);
    } catch (_) {}
  }

  Future<void> _resumeAudio() async {
    try {
      await _player?.play();
      setState(() => _isPlaying = true);
    } catch (_) {}
  }

  Future<void> _approve(String sermonId) async {
    final db = FirebaseDatabase.instance.ref('sermons');
    final snapshot = await db.child('pending').child(sermonId).get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from(snapshot.value as Map);
    // Fresh timestamp + status flip at the moment it becomes visible in
    // the feed — same fix noted in the Kotlin source (avoids sorting by
    // original upload time instead of approval time).
    data['status'] = 'approved';
    data['timestamp'] = DateTime.now().millisecondsSinceEpoch;

    await db.child('approved').child(sermonId).set(data);
    await db.child('pending').child(sermonId).remove();
  }

  Future<void> _reject(String sermonId) async {
    final db = FirebaseDatabase.instance.ref('sermons');
    final snapshot = await db.child('pending').child(sermonId).get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from(snapshot.value as Map);
    data['status'] = 'rejected';
    data['timestamp'] = DateTime.now().millisecondsSinceEpoch;

    await db.child('rejected').child(sermonId).set(data);
    await db.child('pending').child(sermonId).remove();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return AdminPinGate(onUnlock: () => setState(() {}));
    }
    return Scaffold(
      body: Container(
        padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE8F0FF), Colors.white],
          ),
        ),
        child: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pending.isEmpty) {
      return const Center(
        child: Text('No Pending Audio', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      );
    }
    return Column(
      children: [
        const Text(
          'AUDIO APPROVAL',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 30, color: Color(0xFF2346A0)),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 90),
            itemCount: _pending.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (context, index) => _buildCard(_pending[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(Map<String, dynamic> audio) {
    final title = audio['title']?.toString() ?? 'Untitled';
    final desc = audio['description']?.toString() ?? '';
    final url = audio['audioUrl']?.toString();
    final id = audio['id']?.toString();
    final status = audio['status']?.toString();

    final statusLabel = switch (status) {
      'approved' => '🟢 APPROVED',
      'pending' => '🟡 PENDING',
      _ => '🔴 REJECTED',
    };
    final statusColor = switch (status) {
      'approved' => Colors.green,
      'pending' => const Color(0xFFFF9800),
      _ => Colors.red,
    };

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 21)),
            const SizedBox(height: 12),
            Text(desc),
            const SizedBox(height: 12),
            Text(statusLabel, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
            if (url != null && url.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3366FF)),
                    onPressed: () {
                      if (_playingUrl == url && _isPlaying) {
                        _pauseAudio();
                      } else if (_playingUrl == url) {
                        _resumeAudio();
                      } else {
                        _playAudio(url);
                      }
                    },
                    child: Text(
                      _playingUrl != url ? '▶ Play' : (_isPlaying ? '⏸ Pause' : '▶ Resume'),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade600),
                    onPressed: _releasePlayer,
                    child: const Text('⏹ Stop', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0A8754)),
                    onPressed: id == null ? null : () => _approve(id),
                    child: const Text('Approve', style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
                    onPressed: id == null ? null : () => _reject(id),
                    child: const Text('Reject', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}