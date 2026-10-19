import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../data/profile_photo_cache.dart';
import '../../util/base64_image_cache.dart';

/// Up to two initials taken from the words of [name] that start with a
/// letter — so "+232 31 932 652" (an unsaved contact shown by number) gives
/// none and the caller draws a person icon instead of a "+".
String avatarInitials(String name, {int max = 2}) {
  final letter = RegExp(r'\p{L}', unicode: true);
  final out = <String>[];
  for (final word in name.trim().split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    // By code point, not code unit: names in styled Unicode letters
    // (𝑆𝑎𝑚𝑢𝑒𝑙) are surrogate pairs.
    final first = String.fromCharCode(word.runes.first);
    if (!letter.hasMatch(first)) continue;
    out.add(first.toUpperCase());
    if (out.length == max) break;
  }
  return out.join();
}

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

  Uint8List? _decodedBytes() => Base64ImageCache.decode(photoUrl);

  /// Initials when the name has letters; a person icon for a bare number
  /// (unsaved contacts are shown by number, whose first character is "+").
  Widget _fallback() {
    final initials = avatarInitials(name);
    if (initials.isEmpty) {
      return Icon(Icons.person, color: Colors.white, size: size * 0.6);
    }
    return Text(
      initials,
      style: TextStyle(
          color: Colors.white, fontWeight: FontWeight.bold, fontSize: size / 2.6),
    );
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

    // Profile photos come from a camera crop and can be many hundreds of px
    // square; decoding them at full size to fill a ~44 px circle wastes a
    // large chunk of the image cache per avatar. Cap the decode at the
    // avatar's real pixel size.
    final decodePx = (size * MediaQuery.devicePixelRatioOf(context)).ceil();

    Widget avatar = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: bytes != null
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: decodePx,
                cacheHeight: decodePx,
              )
            : Container(
                color: _colorForName,
                alignment: Alignment.center,
                child: _fallback(),
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