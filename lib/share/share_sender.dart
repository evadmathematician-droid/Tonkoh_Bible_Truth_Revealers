import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';

import '../cloudinary/cloudinary_upload.dart';
import '../data/chat_summary.dart';
import '../data/local_chat_store.dart';
import '../data/private_message.dart';
import '../data/user_profile.dart';
import '../screens/audio/onesignal_push.dart';
import '../screens/audio/upload_sheet.dart' show generateTitle;
import '../links/link_preview.dart';
import '../screens/chat/chat_helpers.dart' show previewLabelFor, privateChatId;
import '../screens/chat/private_chat_push.dart';
import 'incoming_share.dart';

/// A shared file once it's on Cloudinary.
class UploadedShareFile {
  final SharedFile file;
  final String url;
  const UploadedShareFile(this.file, this.url);
}

/// Sends shared content to the feed and/or private chats, writing the same
/// records the in-app composers do (upload_sheet.dart for the feed,
/// PrivateChatScreen for chats) so it all looks native on every device.
class ShareSender {
  ShareSender._();

  /// Upload once; the URL is reused for every destination.
  static Future<UploadedShareFile> upload(
    SharedFile file, {
    required String folder,
    void Function(int percent)? onProgress,
  }) async {
    String? url;
    String? error;
    await uploadToCloudinary(
      filePath: file.path,
      fileName: file.name,
      resourceType: cloudinaryResourceTypeForMime(file.mimeType),
      folder: folder,
      onProgress: onProgress,
      onSuccess: (u) => url = u,
      onError: (e) => error = e,
    );
    if (url == null) throw Exception(error ?? 'Upload failed');
    return UploadedShareFile(file, url!);
  }

  // ── Feed ───────────────────────────────────────────────────────────────

  /// Media goes into sermons/pending for admin approval, exactly like the
  /// feed's own upload button.
  static Future<void> postMediaToFeed({
    required UserProfile me,
    required UploadedShareFile upload,
    required String caption,
  }) async {
    final id = const Uuid().v4();
    await FirebaseDatabase.instance.ref('sermons/pending/$id').set({
      'id': id,
      'title': generateTitle(caption),
      'description': caption,
      'audioUrl': upload.url,
      'mediaType': upload.file.kind.toUpperCase(),
      'uploadedBy': me.name.isEmpty ? 'user' : me.name,
      'status': 'pending',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'senderId': me.uid,
      'senderName': me.name,
      'senderPhone': me.phone,
    });
  }

  /// A shared link (YouTube, TikTok, any site) for the Audio screen: a
  /// `LINK` post with the full preview, into sermons/pending like every
  /// upload — it appears only after an admin approves it. `audioUrl` stays
  /// empty, so older app versions (which skip such posts) never misdraw it.
  static Future<void> postLinkToFeed({
    required UserProfile me,
    required LinkPreview link,
    required String caption,
  }) async {
    final id = const Uuid().v4();
    final title = link.title.isNotEmpty ? link.title : generateTitle(caption);
    await FirebaseDatabase.instance.ref('sermons/pending/$id').set({
      'id': id,
      'title': title.isEmpty ? link.url : title,
      'description': caption,
      'audioUrl': '',
      'mediaType': 'LINK',
      'link': link.copyWith(sharedText: caption).toMap(),
      'uploadedBy': me.name.isEmpty ? 'user' : me.name,
      'status': 'pending',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'senderId': me.uid,
      'senderName': me.name,
      'senderPhone': me.phone,
    });
  }

  /// Shared plain text for the Audio screen: also waits for approval
  /// (`TEXT`); approving it publishes it as a normal feed text post.
  static Future<void> postTextToFeed({
    required UserProfile me,
    required String text,
  }) async {
    final id = const Uuid().v4();
    await FirebaseDatabase.instance.ref('sermons/pending/$id').set({
      'id': id,
      'title': generateTitle(text),
      'description': text,
      'audioUrl': '',
      'mediaType': 'TEXT',
      'uploadedBy': me.name.isEmpty ? 'user' : me.name,
      'status': 'pending',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'senderId': me.uid,
      'senderName': me.name,
      'senderPhone': me.phone,
    });
  }

  // ── Private chats ─────────────────────────────────────────────────────

  static Future<void> sendToChat({
    required UserProfile me,
    required String otherUid,
    String text = '',
    List<UploadedShareFile> files = const [],
    LinkPreview? link,
  }) async {
    final cid = privateChatId(me.uid, otherUid);
    final messagesRef = FirebaseDatabase.instance.ref('privateChats/$cid/messages');
    var lastLabel = '';
    var lastTs = 0;

    for (final f in files) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final newRef = messagesRef.push();
      final message = PrivateMessage(
        id: newRef.key ?? '',
        type: f.file.kind,
        fileUrl: f.url,
        fileName: f.file.name,
        mimeType: f.file.mimeType,
        timestamp: ts,
        senderId: me.uid,
        senderName: me.name,
        senderPhone: me.phone,
      );
      await LocalChatStore.instance.insert(cid, message);
      await newRef.set(message.toFirebaseMap());
      lastLabel = switch (f.file.kind) {
        'image' => '📷 Photo',
        'video' => '🎥 Video',
        'audio' => '🎵 Audio',
        _ => '📎 ${f.file.name}',
      };
      lastTs = ts;
    }

    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final newRef = messagesRef.push();
      final withCard = link != null && trimmed.contains(link.url);
      final message = PrivateMessage(
        id: newRef.key ?? '',
        text: trimmed,
        type: withCard ? 'link' : 'text',
        link: withCard ? link : null,
        timestamp: ts,
        senderId: me.uid,
        senderName: me.name,
        senderPhone: me.phone,
      );
      await LocalChatStore.instance.insert(cid, message);
      await newRef.set(message.toFirebaseMap());
      lastLabel = withCard ? previewLabelFor(message) : trimmed;
      lastTs = ts;
    }

    if (lastTs == 0) return;
    await _writeChatSummaries(me, otherUid, cid, lastLabel, lastTs);
    unawaited(sendPrivateChatPushNotification(
      otherUid: otherUid,
      chatId: cid,
      senderName: me.name,
      messageBody: lastLabel,
      senderUid: me.uid,
    ));
  }

  /// Same summary writes as PrivateChatScreen._writeChatSummaries.
  static Future<void> _writeChatSummaries(UserProfile me, String otherUid,
      String cid, String lastMessage, int timestamp) async {
    final db = FirebaseDatabase.instance;
    var otherName = '';
    var otherPhoto = '';
    try {
      final snap = await db.ref('users/$otherUid').get();
      final v = snap.value;
      if (v is Map) {
        otherName = (v['name'] ?? '') as String;
        otherPhoto = (v['photoUrl'] ?? '') as String;
      }
    } catch (_) {}

    await db.ref('userChats/${me.uid}/$cid').set(
          ChatSummary(
            chatId: cid,
            otherUid: otherUid,
            otherName: otherName.isEmpty ? 'Chat' : otherName,
            otherPhotoUrl: otherPhoto,
            lastMessage: lastMessage,
            lastTimestamp: timestamp,
            unread: 0,
            lastReadTimestamp: timestamp,
          ).toFirebaseMap(),
        );

    final recipientRef = db.ref('userChats/$otherUid/$cid');
    await recipientRef.update({
      'otherUid': me.uid,
      'otherName': me.name.isEmpty ? me.phone : me.name,
      'otherPhotoUrl': me.photoUrl,
      'lastMessage': lastMessage,
      'lastTimestamp': timestamp,
    });
    await recipientRef.child('unread').runTransaction((current) {
      final n = (current as num?)?.toInt() ?? 0;
      return Transaction.success(n + 1);
    });
  }

  /// Broadcast push for a text/link posted to the feed (the in-app composer
  /// does the same after AudioFeedProvider.sendTextMessage).
  static void notifyFeedText(UserProfile me, String text) {
    unawaited(sendAudioPushNotification(
      senderName: me.name,
      messageBody: text,
      senderUid: me.uid,
    ));
  }
}
