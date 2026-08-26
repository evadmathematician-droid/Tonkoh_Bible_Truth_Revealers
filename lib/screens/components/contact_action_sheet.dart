import 'package:flutter/material.dart';
import '../../data/app_contact.dart';

/// Equivalent of ContactActionSheet.kt. Same "dumb sheet" philosophy —
/// this only renders the three actions; the caller (ContactScreen)
/// decides what each one actually does.
Future<void> showContactActionSheet({
  required BuildContext context,
  required AppContact contact,
  required void Function(AppContact) onMessage,
  required void Function(AppContact) onVoiceCall,
  required void Function(AppContact) onVideoCall,
}) {
  return showModalBottomSheet(
    context: context,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 2, top: 8),
                child: Text(contact.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 12),
                child: Text(contact.phone, style: const TextStyle(color: Colors.grey)),
              ),
              _ActionItem(
                icon: Icons.message,
                label: 'Message',
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