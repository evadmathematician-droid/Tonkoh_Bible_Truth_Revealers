import 'package:flutter/material.dart';
import '../../data/app_contact.dart';
import 'profile_avatar.dart';

class ContactRow extends StatelessWidget {
  final AppContact contact;
  final VoidCallback onTap;
  final VoidCallback? onAvatarTap;

  const ContactRow({
    super.key,
    required this.contact,
    required this.onTap,
    this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CachedProfileAvatar(uid: contact.uid, name: contact.name, size: 44, onTap: onAvatarTap),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(contact.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    Text(contact.phone, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}