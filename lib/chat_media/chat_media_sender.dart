import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../cloudinary/cloudinary_upload.dart';
import '../data/chat_sync_service.dart';
import '../data/local_chat_store.dart';
import '../data/private_message.dart';
import '../util/image_shrink.dart';

/// A photo or video chosen on the preview screen, ready to send.
class OutgoingMedia {
  const OutgoingMedia({
    required this.path,
    required this.isVideo,
    this.caption = '',
    this.quality = ImageQuality.standard,
  });

  final String path;
  final bool isVideo;
  final String caption;
  final ImageQuality quality;
}

/// Sends chat photos and videos WhatsApp-style: each one appears in the
/// chat at once (local file + progress ring), is shrunk off the UI thread,
/// uploaded, and only then handed to [ChatSyncService] as a normal
/// message with the Cloudinary link.
///
/// A photo that hasn't uploaded within [imageTimeout] — or a video whose
/// upload stalls for 60 s — is marked failed ("Tap to retry") instead of
/// spinning forever. Runs outside any screen, so leaving the chat doesn't
/// stop it.
class ChatMediaSender {
  ChatMediaSender._();
  static final ChatMediaSender instance = ChatMediaSender._();

  static const Duration imageTimeout = Duration(seconds: 60);

  final Map<String, ValueNotifier<double?>> _progress = {};
  final Set<String> _active = {};

  /// Upload progress 0–1 for an uploading message (null = preparing).
  ValueListenable<double?> progressOf(String messageId) =>
      _progress.putIfAbsent(messageId, () => ValueNotifier<double?>(null));

  /// Adds every item to the chat now, then uploads them one by one.
  ///
  /// [template] carries the sender fields and any reply quote; ids and
  /// timestamps come from [newId]. Items keep their order.
  Future<void> sendAll({
    required String chatId,
    required String otherUid,
    required PrivateMessage template,
    required String Function() newId,
    required List<OutgoingMedia> items,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final jobs = <(PrivateMessage, OutgoingMedia)>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final message = template.copyWith(
        id: newId(),
        type: item.isVideo ? 'video' : 'image',
        text: item.caption.trim(),
        fileUrl: item.path,
        fileName: p.basename(item.path),
        mimeType: item.isVideo ? _videoMime(item.path) : 'image/jpeg',
        timestamp: now + i,
        status: MessageStatus.uploading,
        // Only the first of a group quotes the reply.
        replyToId: i == 0 ? template.replyToId : '',
        replyToText: i == 0 ? template.replyToText : '',
        replyToSenderName: i == 0 ? template.replyToSenderName : '',
      );
      await LocalChatStore.instance.insert(chatId, message);
      jobs.add((message, item));
    }
    for (final (message, item) in jobs) {
      await _upload(chatId, otherUid, message, item.quality);
    }
  }

  bool _recovered = false;

  /// Once per app start, before anything is sent: uploads cut off by the
  /// app closing become "Tap to retry".
  Future<void> recoverAfterRestart() async {
    if (_recovered) return;
    _recovered = true;
    try {
      await LocalChatStore.instance.failStaleUploads();
    } catch (e) {
      debugPrint('ChatMediaSender: recovery failed: $e');
    }
  }

  /// "Tap to retry" on a failed photo / video.
  Future<void> retry(String chatId, String otherUid, String messageId) async {
    final message = await LocalChatStore.instance.byId(chatId, messageId);
    if (message == null || message.status != MessageStatus.failed) return;
    await _upload(chatId, otherUid, message, ImageQuality.standard);
  }

  Future<void> _upload(String chatId, String otherUid, PrivateMessage message,
      ImageQuality quality) async {
    if (!_active.add(message.id)) return;
    final progress =
        _progress.putIfAbsent(message.id, () => ValueNotifier<double?>(null));
    progress.value = null;
    await LocalChatStore.instance
        .insert(chatId, message.copyWith(status: MessageStatus.uploading));

    final isVideo = message.type == 'video';
    try {
      final localPath = message.fileUrl;
      if (!await File(localPath).exists()) {
        throw CloudinaryUploadException('The file is no longer on this phone.');
      }
      var uploadPath = localPath;
      if (!isVideo) {
        // The photo may already be a shrunk copy (from the preview
        // screen); shrinking it again is skipped when it's small enough.
        final small = await ImageShrink.shrink(localPath, quality);
        if (small != null && small.path != localPath) {
          uploadPath = small.path;
          // Keep the app's own copy for the bubble and any retry; the
          // picker's cache file can be cleared by the system.
          message = message.copyWith(fileUrl: uploadPath);
          await LocalChatStore.instance.insert(
              chatId, message.copyWith(status: MessageStatus.uploading));
        }
      }

      final url = await cloudinaryUpload(
        filePath: uploadPath,
        fileName: isVideo ? message.fileName : '${p.basenameWithoutExtension(message.fileName)}.jpg',
        resourceType: isVideo ? 'video' : 'image',
        folder: CloudinaryConfig.chatMediaFolder,
        totalTimeout: isVideo ? null : imageTimeout,
        onProgress: (f) => progress.value = f,
      );

      // The sender's own bubble then shows the photo it already has,
      // instead of downloading it again.
      if (!isVideo) {
        try {
          await DefaultCacheManager().putFile(
              url, await File(uploadPath).readAsBytes(),
              fileExtension: 'jpg');
        } catch (_) {}
      }

      final sent = message.copyWith(
        fileUrl: url,
        status: MessageStatus.pending,
      );
      await LocalChatStore.instance.insert(chatId, sent);
      final caption = sent.text;
      unawaited(ChatSyncService.instance.send(
        chatId: chatId,
        otherUid: otherUid,
        message: sent,
        preview: '${isVideo ? '🎥 Video' : '📷 Photo'}'
            '${caption.isEmpty ? '' : ': $caption'}',
      ));
    } catch (e) {
      debugPrint('ChatMediaSender: ${message.id} failed: $e');
      await LocalChatStore.instance
          .insert(chatId, message.copyWith(status: MessageStatus.failed));
    } finally {
      _active.remove(message.id);
      // Not disposed: a bubble may still be listening until it rebuilds.
      _progress.remove(message.id);
    }
  }

  static String _videoMime(String path) => switch (p.extension(path).toLowerCase()) {
        '.mov' => 'video/quicktime',
        '.mkv' => 'video/x-matroska',
        '.3gp' => 'video/3gpp',
        '.webm' => 'video/webm',
        _ => 'video/mp4',
      };
}
