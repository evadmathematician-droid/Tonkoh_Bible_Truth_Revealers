import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/chat_summary.dart';
import '../data/display_names.dart';
import '../data/local_chat_store.dart';
import 'components/profile_avatar.dart';

/// The "Discussions" list. Drawn from the phone's saved chat list
/// (LocalChatStore), so it appears instantly — offline too — with last
/// message, time and unread count; ChatSyncService keeps that list in step
/// with `userChats/{me}` in the background.
class DiscussionsScreen extends StatefulWidget {
  const DiscussionsScreen({super.key});

  @override
  State<DiscussionsScreen> createState() => _DiscussionsScreenState();
}

class _DiscussionsScreenState extends State<DiscussionsScreen> {
  // Already in memory if the list was read this session: no spinner at all.
  List<ChatSummary> _chats =
      ChatSummary.dedupeByPerson(LocalChatStore.instance.cachedChats ?? const []);
  bool _isLoading = LocalChatStore.instance.cachedChats == null;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = LocalChatStore.instance.chatsChanged.listen((_) => _reload());
    _reload();
  }

  Future<void> _reload() async {
    final list = await LocalChatStore.instance.chats();
    if (!mounted) return;
    setState(() {
      // Collapse rows that point at the same person — one phone number is
      // one account, so legacy / differently-formatted duplicates must not
      // show as separate chats. dedupeByPerson also sorts newest-first.
      _chats = ChatSummary.dedupeByPerson(list);
      _isLoading = false;
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

  @override
  Widget build(BuildContext context) {
    final names = context.watch<DisplayNames>();
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
          final name = names.nameFor(chat.otherUid);
          return ListTile(
            // Saved photo from the phone, refreshed in the background.
            leading: CachedProfileAvatar(
                uid: chat.otherUid, name: name, size: 48),
            // Saved-contact name, or just the number for anyone not in
            // the phone's contacts (never their self-chosen profile name).
            title: Text(
              name,
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