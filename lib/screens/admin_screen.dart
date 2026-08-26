import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

import '../screens/auth/auth_manager.dart';
import '../screens/components/admin_pin_gate.dart';

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
  @override
  Widget build(BuildContext context) {
    if (!AuthManager.isAdminUnlockedThisSession) {
      return AdminPinGate(onUnlock: () => setState(() {}));
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

  @override
  void initState() {
    super.initState();
    final ref = FirebaseDatabase.instance.ref('feedback');
    ref.onValue.listen((event) {
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
      setState(() => _isLoading = false);
    });
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
                                      color: badgeColor.withOpacity(0.15),
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

