import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

/// pubspec.yaml:
///   gal: ^2.3.0
///
/// iOS Info.plist:
///   <key>NSPhotoLibraryAddUsageDescription</key>
///   <string>Save photos and videos from chats to your library.</string>
///
/// Android: gal handles scoped-storage permissions itself on modern
/// Android; for API <29 add WRITE_EXTERNAL_STORAGE per gal's README.

enum MediaSaveResult {
  success,
  permissionDenied,
  notEnoughSpace,
  unsupportedFormat,
  failed,
}

/// Saves media that's already sitting in the app's own local storage
/// (via LocalChatStore's file cache) out to the device's Photos /
/// Gallery app. This is separate from — and in addition to —
/// LocalChatStore, which is the app's private message history and
/// isn't visible outside the app.
class MediaSaverService {
  Future<MediaSaveResult> saveImage(String filePath, {String? album}) =>
      _save(filePath, isVideo: false, album: album);

  Future<MediaSaveResult> saveVideo(String filePath, {String? album}) =>
      _save(filePath, isVideo: true, album: album);

  Future<MediaSaveResult> _save(
      String filePath, {
        required bool isVideo,
        String? album,
      }) async {
    if (!await File(filePath).exists()) return MediaSaveResult.failed;

    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) return MediaSaveResult.permissionDenied;
    }

    try {
      if (isVideo) {
        await Gal.putVideo(filePath, album: album);
      } else {
        await Gal.putImage(filePath, album: album);
      }
      return MediaSaveResult.success;
    } on GalException catch (e) {
      switch (e.type) {
        case GalExceptionType.accessDenied:
          return MediaSaveResult.permissionDenied;
        case GalExceptionType.notEnoughSpace:
          return MediaSaveResult.notEnoughSpace;
        case GalExceptionType.notSupportedFormat:
          return MediaSaveResult.unsupportedFormat;
        case GalExceptionType.unexpected:
          return MediaSaveResult.failed;
      }
    }
  }
}

/// Small circular "Save" button meant to sit as an overlay in the
/// corner of an image/video message bubble — tap to save that file
/// to the device gallery, with a snackbar confirming success/failure.
class SaveMediaButton extends StatefulWidget {
  const SaveMediaButton({
    super.key,
    required this.filePath,
    required this.isVideo,
    this.album,
  });

  final String filePath;
  final bool isVideo;
  final String? album;

  @override
  State<SaveMediaButton> createState() => _SaveMediaButtonState();
}

class _SaveMediaButtonState extends State<SaveMediaButton> {
  final _saver = MediaSaverService();
  bool _saving = false;

  Future<void> _handleSave() async {
    if (_saving) return;
    setState(() => _saving = true);

    final result = widget.isVideo
        ? await _saver.saveVideo(widget.filePath, album: widget.album)
        : await _saver.saveImage(widget.filePath, album: widget.album);

    if (!mounted) return;
    setState(() => _saving = false);

    final message = switch (result) {
      MediaSaveResult.success => 'Saved to gallery',
      MediaSaveResult.permissionDenied => 'Gallery permission denied',
      MediaSaveResult.notEnoughSpace => 'Not enough space to save',
      MediaSaveResult.unsupportedFormat => 'Unsupported file format',
      MediaSaveResult.failed => 'Couldn\'t save file',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.45),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _handleSave,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: _saving
              ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
              : const Icon(Icons.download_rounded, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}