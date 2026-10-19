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

class MainNavHost extends StatelessWidget {
  final String? startChatUid;
  const MainNavHost({super.key, this.startChatUid});

  @override
  Widget build(BuildContext context) {
    final router = GoRouter(
      initialLocation: startChatUid != null && startChatUid!.isNotEmpty
          ? '/privateChat/$startChatUid'
          : '/audio',
      routes: [
        GoRoute(path: '/contact', builder: (c, s) => const ContactScreen()),
        GoRoute(path: '/audio', builder: (c, s) => const AudioScreen()),
        GoRoute(path: '/message', builder: (c, s) => const ComingSoonScreen('Bible Facts')),
        GoRoute(path: '/feedback', builder: (c, s) => const FeedbackScreen()),
        GoRoute(path: '/chatList', builder: (c, s) => const DiscussionsScreen()),
        GoRoute(path: '/admin', builder: (c, s) => const AdminScreen()),
        GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen()),
        GoRoute(path: '/adminApproval', builder: (c, s) => const AdminAudioApprovalScreen()),

        GoRoute(
          path: '/privateChat/:otherUid',
          builder: (context, state) {
            final otherUid = state.pathParameters['otherUid']!;
            return PrivateChatScreen(otherUid: otherUid);
          },
        ),
      ],
    );

    return Router.withConfig(config: router);
  }
}