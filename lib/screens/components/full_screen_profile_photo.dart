import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Equivalent of FullScreenProfilePhoto.kt — a full-bleed dismissible
/// overlay, not a route/destination. Show it with showGeneralDialog or
/// showDialog(barrierColor: transparent) from a nullable state, same
/// pattern as the Kotlin `showPhotoFor: AppContact?` usage note.
///
/// isOwnProfile is the only edit gate, same as Kotlin — every other
/// viewer always gets pure view mode.
class FullScreenProfilePhoto extends StatelessWidget {
  final String name;
  final String? photoUrl; // Base64, same format as UserProfile.photoUrl
  final bool isOwnProfile;
  final VoidCallback onDismiss;
  final VoidCallback? onEditRequested;

  const FullScreenProfilePhoto({
    super.key,
    required this.name,
    required this.photoUrl,
    required this.isOwnProfile,
    required this.onDismiss,
    this.onEditRequested,
  });

  Uint8List? _decodedBytes() {
    if (photoUrl == null || photoUrl!.isEmpty) return null;
    try {
      return base64Decode(photoUrl!);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decodedBytes();

    return GestureDetector(
      // Backdrop tap dismisses.
      onTap: onDismiss,
      child: Container(
        color: Colors.black.withOpacity(0.85),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              // Absorbs taps so they don't bubble to the backdrop.
              onTap: () {},
              child: ClipOval(
                child: SizedBox(
                  width: 280,
                  height: 280,
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.cover)
                      : Container(
                    color: const Color(0xFF37474F),
                    alignment: Alignment.center,
                    child: const Icon(Icons.person, color: Colors.white, size: 96),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            if (isOwnProfile && onEditRequested != null) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () {},
                child: ClipOval(
                  child: Material(
                    color: const Color(0xFF102A72),
                    child: InkWell(
                      onTap: onEditRequested,
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(Icons.camera_alt, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}