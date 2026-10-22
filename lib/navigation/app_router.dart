import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../screens/admin_audio_approval_screen.dart';
import '../screens/audio_screen.dart'; // adjust path if yours differs
import '../screens/contact_screen.dart';
import '../screens/discussions_screen.dart';
import '../screens/feedback_screen.dart';
import '../screens/profile/settings_screen.dart';
import '../screens/chat/private_chat_screen.dart'; // add this import

import '../screens/admin_screen.dart';

// ...inside routes:

class ComingSoonScreen extends StatelessWidget {
  final String label;
  const ComingSoonScreen(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '$label is coming soon.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}

class MainNavHost extends StatefulWidget {
  final String? startChatUid;
  const MainNavHost({super.key, this.startChatUid});

  @override
  State<MainNavHost> createState() => _MainNavHostState();
}

class _MainNavHostState extends State<MainNavHost> {
  // Created once: rebuilding the host (the auth gate re-rendering) must
  // never reset navigation back to the first screen.
  late final GoRouter _router =
      _buildRouter(widget.startChatUid ?? _takePendingChat());

  @override
  void initState() {
    super.initState();
    _liveRouter = _router;
  }

  @override
  void dispose() {
    if (identical(_liveRouter, _router)) _liveRouter = null;
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Router.withConfig(config: _router);
}

GoRouter? _liveRouter;
String? _pendingChatUid;

String? _takePendingChat() {
  final uid = _pendingChatUid;
  _pendingChatUid = null;
  return uid;
}

/// Opens the private chat with [otherUid] — from a tapped message
/// notification. Before the signed-in screens exist (cold start from the
/// notification) it's remembered and becomes the first screen. Does
/// nothing if that chat is already open.
void openPrivateChat(String otherUid) {
  final router = _liveRouter;
  if (router == null) {
    _pendingChatUid = otherUid;
    return;
  }
  final path = '/privateChat/$otherUid';
  if (router.state.uri.path == path) return;
  router.push(path);
}

/// The chat currently on screen, if any (to skip its own notifications).
String? get openPrivateChatUid {
  final path = _liveRouter?.state.uri.path ?? '';
  const prefix = '/privateChat/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : null;
}

GoRouter _buildRouter(String? startChatUid) {
  return GoRouter(
    initialLocation: startChatUid != null && startChatUid.isNotEmpty
        ? '/privateChat/$startChatUid'
        : '/audio',
    routes: [
      GoRoute(path: '/contact', builder: (c, s) => const ContactScreen()),
      GoRoute(path: '/audio', builder: (c, s) => const AudioScreen()),
      GoRoute(
          path: '/message',
          builder: (c, s) => const ComingSoonScreen('Bible Facts')),
      GoRoute(path: '/feedback', builder: (c, s) => const FeedbackScreen()),
      GoRoute(path: '/chatList', builder: (c, s) => const DiscussionsScreen()),
      GoRoute(path: '/admin', builder: (c, s) => const AdminScreen()),
      GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen()),
      GoRoute(
          path: '/adminApproval',
          builder: (c, s) => const AdminAudioApprovalScreen()),
      GoRoute(
        path: '/privateChat/:otherUid',
        builder: (context, state) {
          final otherUid = state.pathParameters['otherUid']!;
          return PrivateChatScreen(otherUid: otherUid);
        },
      ),
    ],
  );
}
