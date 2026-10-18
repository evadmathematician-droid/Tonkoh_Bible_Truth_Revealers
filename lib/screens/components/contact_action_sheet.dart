import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/app_contact.dart';
import '../../data/display_names.dart';
import 'profile_avatar.dart';

/// Equivalent of ContactActionSheet.kt. Same 'dumb sheet' philosophy —
/// this only renders the actions; the caller decides what each one
/// actually does. Used by the Contacts screen and by tapping a member's
/// photo or name in the audio feed (which also passes [onReply] and, for
/// numbers not saved on this phone, [onSaveContact]).
///
/// Everything here is private between the two people — starting a chat or
/// call from the feed posts nothing to the feed and notifies no one else.
Future<void> showContactActionSheet({
  required BuildContext context,
  required AppContact contact,
  required void Function(AppContact) onMessage,
  required void Function(AppContact) onVoiceCall,
  required void Function(AppContact) onVideoCall,
  VoidCallback? onReply,
  void Function(AppContact)? onSaveContact,
  String messageLabel = 'Message',
}) {
  return showModalBottomSheet(
    context: context,
    builder: (context) {
      final number = contact.phone.startsWith('+')
          ? formatPhoneForDisplay(contact.phone)
          : contact.phone;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    ProfileAvatar(
                        name: contact.name, photoUrl: contact.photoUrl, size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(contact.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16),
                              overflow: TextOverflow.ellipsis),
                          if (number != contact.name)
                            Text(number,
                                style: const TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                    if (contact.phone.isNotEmpty)
                      IconButton(
                        tooltip: 'Copy number',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: contact.phone));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Number copied'),
                                  duration: Duration(seconds: 1)),
                            );
                          }
                        },
                      ),
                  ],
                ),
              ),
              _ActionItem(
                icon: Icons.message,
                label: messageLabel,
                onTap: () {
                  Navigator.pop(context);
                  onMessage(contact);
                },
              ),
              _ActionItem(
                icon: Icons.call,
                label: 'Voice Call',
                onTap: () {
                  Navigator.pop(context);
                  onVoiceCall(contact);
                },
              ),
              _ActionItem(
                icon: Icons.videocam,
                label: 'Video Call',
                onTap: () {
                  Navigator.pop(context);
                  onVideoCall(contact);
                },
              ),
              if (onReply != null)
                _ActionItem(
                  icon: Icons.reply,
                  label: 'Reply',
                  onTap: () {
                    Navigator.pop(context);
                    onReply();
                  },
                ),
              if (onSaveContact != null)
                _ActionItem(
                  icon: Icons.person_add_alt_1,
                  label: 'Save contact',
                  onTap: () {
                    Navigator.pop(context);
                    onSaveContact(contact);
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionItem({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF365DDB)),
            const SizedBox(width: 20),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}