import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

import '../admin/admin_pin.dart';

class FeedbackItem {
  final String id;
  final String type;
  final String message;
  final String phone;
  final int timestamp;

  FeedbackItem({
    required this.id,
    required this.type,
    required this.message,
    required this.phone,
    required this.timestamp,
  });

  factory FeedbackItem.fromMap(String id, Map<dynamic, dynamic> map) {
    return FeedbackItem(
      id: id,
      type: map['type'] as String? ?? '',
      message: map['message'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
    );
  }
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  // Asked once per app session (until the app is closed).
  bool _isUnlocked = AdminPin.instance.unlockedThisSession;

  @override
  Widget build(BuildContext context) {
    if (!_isUnlocked) {
      return _AdminPinGate(onUnlock: () => setState(() => _isUnlocked = true));
    }
    return const _AdminPanel();
  }
}

class _AdminPanel extends StatefulWidget {
  const _AdminPanel();

  @override
  State<_AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<_AdminPanel> {
  List<FeedbackItem> _feedback = [];
  bool _isLoading = true;
  StreamSubscription<DatabaseEvent>? _feedbackSub;

  @override
  void initState() {
    super.initState();
    final ref = FirebaseDatabase.instance.ref('feedback');
    _feedbackSub = ref.onValue.listen((event) {
      if (!mounted) return;
      final value = event.snapshot.value;
      final list = <FeedbackItem>[];
      if (value is Map) {
        value.forEach((key, child) {
          if (child is Map) {
            list.add(FeedbackItem.fromMap(key as String, child));
          }
        });
      }
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      setState(() {
        _feedback = list;
        _isLoading = false;
      });
    }, onError: (_) {
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  void dispose() {
    _feedbackSub?.cancel();
    super.dispose();
  }

  String _formatTimestamp(int millis) {
    if (millis <= 0) return '';
    return DateFormat('MMM d, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(millis));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF163E8E), Color(0xFFEEF4FF)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
            child: Column(
              children: [
                const Text(
                  'ADMIN PANEL',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const SizedBox(height: 35),
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  elevation: 10,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const Text(
                          'Manage uploaded sermons and approve content',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          height: 60,
                          child: ElevatedButton(
                            onPressed: () => context.push('/adminApproval'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2E5BFF),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            ),
                            child: const Text('Review Uploaded Audio',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Submitted Feedback',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
                const SizedBox(height: 12),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: CircularProgressIndicator(color: Colors.white),
                  )
                else if (_feedback.isEmpty)
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    child: const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No feedback submitted yet.', style: TextStyle(color: Colors.grey)),
                    ),
                  )
                else
                  Column(
                    children: _feedback.map((item) {
                      final isChallenge = item.type == 'challenge';
                      final badgeColor = isChallenge ? const Color(0xFFFF9800) : const Color(0xFF4CAF50);
                      final badgeLabel = isChallenge ? 'Challenge' : 'Improvement';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: badgeColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(badgeLabel,
                                        style: TextStyle(color: badgeColor, fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                                  Text(_formatTimestamp(item.timestamp),
                                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(item.message, style: const TextStyle(fontSize: 14, color: Color(0xFF1B1B1B))),
                              if (item.phone.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text('📱 ${item.phone}',
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF1565C0), fontWeight: FontWeight.w500)),
                              ],
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdminPinGate extends StatefulWidget {
  final VoidCallback onUnlock;
  const _AdminPinGate({required this.onUnlock});

  @override
  State<_AdminPinGate> createState() => _AdminPinGateState();
}

class _AdminPinGateState extends State<_AdminPinGate> {
  final _pinController = TextEditingController();
  String? _error;
  bool _checking = false;
  bool _showPin = false;
  Timer? _lockTicker;

  // The PIN is the gate. (The earlier extra check against the server's
  // admins/{phone} list blocked everyone — that node never existed. The
  // database rules still use admins/ for approve/reject writes.)
  Future<void> _unlock() async {
    if (_checking) return;
    setState(() => _checking = true);
    final error = await AdminPin.instance.verify(_pinController.text);
    if (!mounted) return;
    setState(() => _checking = false);
    if (error == null) {
      widget.onUnlock();
      return;
    }
    setState(() {
      _error = error;
      _pinController.clear();
    });
    _startLockTicker();
  }

  // While locked out, refresh the countdown and re-enable Enter at the end.
  void _startLockTicker() {
    _lockTicker?.cancel();
    if (AdminPin.instance.lockRemaining == null) return;
    _lockTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      final left = AdminPin.instance.lockRemaining;
      setState(() {
        _error = left == null
            ? null
            : 'Too many wrong tries. Try again in ${left.inSeconds + 1} s.';
      });
      if (left == null) t.cancel();
    });
  }

  @override
  void dispose() {
    _lockTicker?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = AdminPin.instance.lockRemaining != null;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF163E8E), Color(0xFFEEF4FF)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              elevation: 10,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🔒 Admin Access',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF163E8E))),
                    const SizedBox(height: 8),
                    const Text('Enter the 4-digit PIN to continue',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey)),
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('adminPinField'),
                      controller: _pinController,
                      obscureText: !_showPin,
                      obscuringCharacter: '●',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      maxLength: 4,
                      autofocus: true,
                      enabled: !locked,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, letterSpacing: 12),
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) => _unlock(),
                      decoration: InputDecoration(
                        labelText: 'PIN',
                        counterText: '',
                        errorText: _error,
                        errorMaxLines: 2,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                        suffixIcon: IconButton(
                          tooltip: _showPin ? 'Hide PIN' : 'Show PIN',
                          icon: Icon(_showPin
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () => setState(() => _showPin = !_showPin),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        key: const Key('adminPinEnter'),
                        onPressed: (_checking || locked) ? null : _unlock,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E5BFF),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        child: _checking
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Enter',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
