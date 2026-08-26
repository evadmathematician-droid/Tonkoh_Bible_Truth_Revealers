import 'package:flutter/material.dart';

class AudioDrawerContent extends StatelessWidget {
  final String? currentUid;
  final int totalUnread;
  final VoidCallback onNavigateContacts;
  final VoidCallback onNavigateBibleFacts;
  final VoidCallback onNavigateFeedback;
  final VoidCallback onNavigateAdmin;
  final VoidCallback onNavigateDiscussions;
  final VoidCallback onNavigateSettings;
  final VoidCallback onClose;

  const AudioDrawerContent({
    super.key,
    required this.currentUid,
    required this.totalUnread,
    required this.onNavigateContacts,
    required this.onNavigateBibleFacts,
    required this.onNavigateFeedback,
    required this.onNavigateAdmin,
    required this.onNavigateDiscussions,
    required this.onNavigateSettings,
    required this.onClose,
  });

  Widget _tile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    int? badgeCount,
  }) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF102A72)),
      title: Text(label),
      trailing: (badgeCount != null && badgeCount > 0)
          ? CircleAvatar(
        radius: 10,
        backgroundColor: const Color(0xFFE53935),
        child: Text(
          badgeCount > 99 ? '99+' : '$badgeCount',
          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
        ),
      )
          : null,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            color: const Color(0xFFE3F2FD),
            child: const Text(
              'TONKOH BIBLE\nTRUTH REVEALERS',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF102A72)),
            ),
          ),
          _tile(icon: Icons.menu_book, label: 'Bible Facts', onTap: onNavigateBibleFacts),
          _tile(
            icon: Icons.chat_bubble_outline,
            label: 'Discussions',
            onTap: onNavigateDiscussions,
            badgeCount: totalUnread,
          ),
          // Moved here per your request — was previously mislabeled "Home"
          // and positioned first. This is ContactScreen.kt's equivalent:
          // the matched-contacts list with call/message actions, not an
          // app "home" page.
          _tile(icon: Icons.contacts_outlined, label: 'Contacts', onTap: onNavigateContacts),
          _tile(icon: Icons.feedback_outlined, label: 'Feedback', onTap: onNavigateFeedback),
          if (currentUid != null)
            _tile(icon: Icons.admin_panel_settings_outlined, label: 'Admin', onTap: onNavigateAdmin),
          _tile(icon: Icons.settings_outlined, label: 'Settings', onTap: onNavigateSettings),
          const Spacer(),
          _tile(icon: Icons.close, label: 'Close', onTap: onClose),
        ],
      ),
    );
  }
}