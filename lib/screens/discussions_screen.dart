import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_database/firebase_database.dart';

import '../data/chat_summary.dart';
import '../screens/auth/auth_manager.dart';

/// Real "Discussions" list — replaces the old `_StubScreen('Chat List')`
/// route. Reads `userChats/{currentUid}` from Firebase Realtime Database
/// (the same node PrivateChatScreen.kt writes chat summaries to) and
/// lets the user tap into an existing private chat.
class DiscussionsScreen extends StatefulWidget {
  const DiscussionsScreen({super.key});

  @override
  State<DiscussionsScreen> createState() => _DiscussionsScreenState();
}

class _DiscussionsScreenState extends State<DiscussionsScreen> {
  String? _currentUid;
  bool _isLoading = true;
  List<ChatSummary> _chats = [];
  StreamSubscription<DatabaseEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _loadCurrentUserAndListen();
  }

  Future<void> _loadCurrentUserAndListen() async {
    await AuthManager.ensureSignedIn(
      onReady: () async {
        final cached = await AuthManager.getCachedProfile();
        if (cached == null) {
          setState(() => _isLoading = false);
          return;
        }
        setState(() => _currentUid = cached.uid);
        _listenToChats(cached.uid);
      },
      onError: (_) {
        setState(() => _isLoading = false);
      },
    );
  }

  void _listenToChats(String uid) {
    final ref = FirebaseDatabase.instance.ref('userChats/$uid');
    _sub = ref.onValue.listen((event) {
      final data = event.snapshot.value;
      final List<ChatSummary> parsed = [];

      if (data is Map) {
        data.forEach((key, value) {
          if (value is Map) {
            parsed.add(ChatSummary.fromMap(key.toString(), value));
          }
        });
      }

      parsed.sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));

      if (mounted) {
        setState(() {
          _chats = parsed;
          _isLoading = false;
        });
      }
    }, onError: (_) {
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _formatTimestamp(int millis) {
    if (millis == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final isToday = date.year == now.year && date.month == now.month && date.day == now.day;
    if (isToday) {
      final h = date.hour % 12 == 0 ? 12 : date.hour % 12;
      final m = date.minute.toString().padLeft(2, '0');
      final ampm = date.hour >= 12 ? 'PM' : 'AM';
      return '$h:$m $ampm';
    }
    return '${date.month}/${date.day}';
  }

  ImageProvider? _avatarFromBase64(String base64Str) {
    if (base64Str.isEmpty) return null;
    try {
      return MemoryImage(base64Decode(base64Str));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discussions'),
        backgroundColor: const Color(0xFF102A72),
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _chats.isEmpty
          ? const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No discussions yet. Start one from a contact.',
            style: TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
      )
          : ListView.separated(
        itemCount: _chats.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final chat = _chats[index];
          final avatar = _avatarFromBase64(chat.otherPhotoUrl);
          return ListTile(
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: const Color(0xFF102A72).withOpacity(0.1),
              backgroundImage: avatar,
              child: avatar == null
                  ? const Icon(Icons.person, color: Color(0xFF102A72))
                  : null,
            ),
            title: Text(
              chat.otherName.isEmpty ? 'Chat' : chat.otherName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              chat.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatTimestamp(chat.lastTimestamp),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (chat.unread > 0) ...[
                  const SizedBox(height: 4),
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: const Color(0xFFE53935),
                    child: Text(
                      chat.unread > 99 ? '99+' : '${chat.unread}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            onTap: () => context.push('/privateChat/${chat.otherUid}'),
          );
        },
      ),
    );
  }
}