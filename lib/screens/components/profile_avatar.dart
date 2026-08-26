import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../data/profile_photo_cache.dart';

class ProfileAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl; // Base64
  final double size;
  final VoidCallback? onTap;

  const ProfileAvatar({
    super.key,
    required this.name,
    required this.photoUrl,
    this.size = 44,
    this.onTap,
  });

  Uint8List? _decodedBytes() {
    if (photoUrl == null || photoUrl!.isEmpty) return null;
    try {
      return base64Decode(photoUrl!);
    } catch (_) {
      return null;
    }
  }

  String get _initials {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).take(2);
    final result = parts.map((p) => p[0].toUpperCase()).join();
    return result.isEmpty ? '?' : result;
  }

  static const _palette = [
    Color(0xFF102A72), Color(0xFF1E88E5), Color(0xFF00897B),
    Color(0xFF6D4C41), Color(0xFF8E24AA), Color(0xFFD81B60),
    Color(0xFF43A047), Color(0xFFF4511E),
  ];

  Color get _colorForName {
    final sum = name.trim().codeUnits.fold<int>(0, (a, b) => a + b);
    return _palette[sum % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decodedBytes();

    Widget avatar = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover)
            : Container(
          color: _colorForName,
          alignment: Alignment.center,
          child: Text(
            _initials,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size / 2.6),
          ),
        ),
      ),
    );

    if (onTap != null) {
      avatar = GestureDetector(onTap: onTap, child: avatar);
    }
    return avatar;
  }
}

/// Equivalent of CachedProfileAvatar.kt. Listens to ProfilePhotoCache so
/// it rebuilds itself once a background-fetched photo arrives, rather
/// than reading the cache once and staying stale.
class CachedProfileAvatar extends StatelessWidget {
  final String? uid;
  final String name;
  final double size;
  final VoidCallback? onTap;

  const CachedProfileAvatar({
    super.key,
    required this.uid,
    required this.name,
    this.size = 44,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ProfilePhotoCache.instance,
      builder: (context, _) {
        final photoUrl = (uid != null && uid!.isNotEmpty)
            ? ProfilePhotoCache.instance.photoFor(uid!)
            : null;
        return ProfileAvatar(name: name, photoUrl: photoUrl, size: size, onTap: onTap);
      },
    );
  }
}