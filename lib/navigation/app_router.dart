import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../screens/admin_audio_approval_screen.dart';
import '../screens/audio_screen.dart'; // adjust path if yours differs
import '../screens/contact_screen.dart';
import '../screens/discussions_screen.dart';
import '../screens/chat/private_chat_screen.dart'; // add this import

import '../screens/admin_screen.dart';
import '../screens/audio/upload_audio_screen.dart';
import '../screens/settings/settings_screen.dart';

// ...inside routes:

class _StubScreen extends StatelessWidget {
  final String label;
  const _StubScreen(this.label);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: Center(child: Text('$label — not yet ported')),
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
  // Created ONCE and reused across rebuilds — building this fresh inside
  // build() (as this used to do) meant ANY rebuild of AuthGate/MainNavHost
  // (a theme change, a web window resize, any unrelated setState above this
  // widget) silently constructed a brand-new GoRouter and reset navigation
  // straight back to initialLocation, regardless of where the user actually
  // was — e.g. jumping back to /audio mid-call or mid-chat.
  late final GoRouter _router = GoRouter(
    initialLocation: widget.startChatUid != null && widget.startChatUid!.isNotEmpty
        ? '/privateChat/${widget.startChatUid}'
        : '/audio',
    routes: [
      GoRoute(path: '/contact', builder: (c, s) => const ContactScreen()),
      GoRoute(path: '/audio', builder: (c, s) => const AudioScreen()),
      GoRoute(path: '/message', builder: (c, s) => const _StubScreen('Message')),
      GoRoute(path: '/feedback', builder: (c, s) => const _StubScreen('Feedback')),
      GoRoute(path: '/chatList', builder: (c, s) => const DiscussionsScreen()),
      GoRoute(path: '/admin', builder: (c, s) => const AdminScreen()),
      GoRoute(path: '/uploadAudio', builder: (c, s) => const UploadAudioScreen()),
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

  @override
  Widget build(BuildContext context) {
    return Router.withConfig(config: _router);
  }
}