import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../auth/auth_manager.dart';
import '../auth/presence_manager.dart';
import '../../cloudinary/cloudinary_upload.dart';
import '../../data/chat_sync_service.dart';
import '../../data/display_names.dart';
import '../../data/local_chat_store.dart';
import '../../data/phone_aliases.dart';
import '../../data/private_message.dart';
import '../../data/profile_photo_cache.dart';
import '../../services/resumable_downloader.dart';
import '../../services/share_service.dart';
import '../../ui/chat_theme.dart';
import '../../ui/linkified_text.dart';
import '../components/full_screen_profile_photo.dart';
import '../../util/chat_time.dart';
import 'chat_helpers.dart';
import 'message_bubbles.dart' hide VoiceMessageBubble;
import '../../services/voice_message_bubble.dart';
import '../chat/private_chat_input.dart';
import 'package:tbtrapp/services/voice_recorder.dart';

// ── CALL IMPORTS ──
import '../../calls/start_call.dart';
import '../../data/user_profile.dart';
// ──────────────────

const _kBrand = Color(0xFF102A72);

class PrivateChatScreen extends StatefulWidget {
  final String otherUid;
  const PrivateChatScreen({super.key, required this.otherUid});

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> {
  // Links from old data may carry a malformed or moved account id.
  late final String _otherUid = resolveUserId(widget.otherUid);

  String? _currentUid;
  String _currentSenderName = '';
  String _currentSenderPhone = '';
  String _currentSenderPhotoUrl = '';
  UserProfile? _currentProfile;

  // The name they gave their own profile — only written into chat-list
  // records. What this screen shows is [_otherUserName].
  String _otherProfileName = '';

  /// Saved-contact name, or just their number if not in my contacts.
  String get _otherUserName => DisplayNames.instance.nameFor(_otherUid);
  String _otherUserPhotoBase64 = '';
  String _otherUserPhone = '';
  String _otherUserCountry = '';
  bool _otherUserOnline = false;
  int _otherUserLastSeen = 0;
  int _otherUserLastReadTimestamp = 0;

  String? _chatId;

  /// Loaded window of the conversation, oldest first. Starts as the newest
  /// [LocalChatStore.pageSize] messages; scrolling up prepends older pages.
  final List<PrivateMessage> _messages = [];
  bool _hasOlder = true;
  bool _loadingOlder = false;
  // The list is reversed (index 0 = newest at the bottom), so it opens on
  // the newest message with no scroll jump.
  final _scrollController = ScrollController();
  final _messageController = TextEditingController();

  StreamSubscription<String>? _localSub;
  final Stopwatch _openTimer = Stopwatch()..start();
  bool _openLogged = false;
  StreamSubscription<DatabaseEvent>? _presenceSub;
  StreamSubscription<DatabaseEvent>? _readReceiptSub;
  Timer? _markReadDebounce;

  final _voiceRecorder = VoiceRecorderService();
  bool _isRecording = false;
  bool _isPaused = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  bool _isUploadingAttachment = false;
  bool _showAttachMenu = false;
  PrivateMessage? _replyingTo;

  /// Selected message ids. Non-empty == selection mode is active.
  final Set<String> _selectedIds = {};
  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Local-first: with the profile already in memory, the chat id and the
    // saved messages are known before the first frame — no blank screen.
    final known = AuthManager.lastKnownProfile;
    if (known != null) _applyProfile(known);
    _otherUserPhotoBase64 =
        ProfilePhotoCache.instance.photoFor(_otherUid) ?? '';
    _init();
    _scrollController.addListener(_onScroll);
  }

  void _applyProfile(UserProfile p) {
    _currentProfile = p;
    _currentUid = p.uid;
    _currentSenderName = p.name;
    _currentSenderPhone = p.phone;
    _currentSenderPhotoUrl = p.photoUrl;
    _chatId = privateChatId(p.uid, _otherUid);
    final saved = LocalChatStore.instance.window(_chatId!);
    if (saved != null && _messages.isEmpty) {
      _messages.addAll(saved);
      _hasOlder = saved.length >= LocalChatStore.pageSize;
      _logOpenTime('memory');
    }
  }

  Future<void> _init() async {
    if (_currentProfile == null) {
      final cached = await AuthManager.getCachedProfile();
      if (cached == null) {
        debugPrint('PrivateChatScreen: no cached profile found — user may '
            'not have completed signup.');
      } else if (mounted) {
        setState(() => _applyProfile(cached));
      }
    }

    final cid = _chatId;
    if (cid != null) {
      _listenLocalMessages();
      unawaited(_reloadWindow());
      // Normally already watched; covers a chat not yet in the chat list.
      ChatSyncService.instance.watchChat(cid);
      _listenReadReceipt();
    }

    await AuthManager.ensureSignedIn(
      onReady: () {
        final uid = _currentUid;
        if (uid != null) PresenceManager.start(uid);
      },
      onError: (msg) => debugPrint('AuthManager.ensureSignedIn failed: $msg'),
    );

    _listenOtherUserProfile();
    _listenPresence();
  }

  void _listenOtherUserProfile() {
    FirebaseDatabase.instance.ref('users/$_otherUid').get().then((snap) {
      final val = snap.value;
      if (!mounted) return;
      if (val is Map) {
        final name = (val['name'] ?? '') as String;
        final phone = (val['phone'] ?? '') as String;
        final photo = (val['photoUrl'] ?? '') as String;
        if (photo.isNotEmpty) {
          ProfilePhotoCache.instance.updateCached(_otherUid, photo);
        }
        setState(() {
          _otherProfileName = name.isNotEmpty ? name : phone;
          _otherUserPhone = phone;
          _otherUserCountry = (val['country'] ?? '') as String;
          if (photo.isNotEmpty) _otherUserPhotoBase64 = photo;
        });
      } else {
        setState(() => _otherProfileName = 'Chat');
      }
    }).catchError((_) {
      // Offline: keep the saved photo / number; nothing to wait for.
      if (mounted && _otherProfileName.isEmpty) {
        setState(() => _otherProfileName = 'Chat');
      }
    });
  }

  void _listenPresence() {
    _presenceSub = FirebaseDatabase.instance
        .ref('presence/$_otherUid')
        .onValue
        .listen((event) {
      final val = event.snapshot.value;
      if (val is Map) {
        setState(() {
          _otherUserOnline = (val['online'] as bool?) ?? false;
          _otherUserLastSeen = (val['lastSeen'] as num?)?.toInt() ?? 0;
        });
      }
    });
  }

  void _listenReadReceipt() {
    final cid = _chatId;
    if (cid == null) return;
    _readReceiptSub = FirebaseDatabase.instance
        .ref('userChats/$_otherUid/$cid/lastReadTimestamp')
        .onValue
        .listen((event) {
      final v = event.snapshot.value;
      setState(() => _otherUserLastReadTimestamp = (v as num?)?.toInt() ?? 0);
    });
  }

  /// Re-reads the loaded window whenever this chat's local messages change
  /// (a message arrived via ChatSyncService, one of mine was sent or
  /// delivered, one was deleted).
  void _listenLocalMessages() {
    final cid = _chatId;
    if (cid == null) return;
    _localSub = LocalChatStore.instance.changes
        .where((changed) => changed == cid)
        .listen((_) => _reloadWindow());
  }

  Future<void> _reloadWindow() async {
    final cid = _chatId;
    if (cid == null) return;
    final store = LocalChatStore.instance;
    final oldest = _messages.isEmpty ? null : _messages.first.timestamp;
    final msgs = oldest == null
        ? await store.latest(cid)
        : await store.since(cid, oldest);
    if (!mounted) return;
    final previousNewest = _messages.isEmpty ? null : _messages.last.id;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
      if (oldest == null) _hasOlder = msgs.length >= LocalChatStore.pageSize;
    });
    _logOpenTime('disk');
    if (msgs.isEmpty || msgs.last.id == previousNewest) return;
    // Something new at the bottom: follow it if I'm already near the
    // bottom (or it's mine), and count it as read while the chat is open.
    if (msgs.last.senderId == _currentUid || _nearBottom) {
      _scrollToBottomIfNeeded();
    }
    _scheduleMarkRead();
  }

  void _logOpenTime(String source) {
    if (_openLogged || _messages.isEmpty) return;
    _openLogged = true;
    final ms = _openTimer.elapsedMilliseconds;
    debugPrint('[ChatOpen] ${_messages.length} messages visible after ${ms}ms '
        '(from $source)');
  }

  /// Older page from the phone when scrolling up to the top of the window.
  Future<void> _loadOlder() async {
    final cid = _chatId;
    if (cid == null || _loadingOlder || !_hasOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    try {
      final older = await LocalChatStore.instance
          .olderThan(cid, _messages.first.timestamp);
      if (!mounted) return;
      setState(() {
        _messages.insertAll(0, older);
        _hasOlder = older.length >= LocalChatStore.pageSize;
      });
    } finally {
      _loadingOlder = false;
    }
  }

  bool get _nearBottom =>
      !_scrollController.hasClients || _scrollController.offset < 240;

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Reversed list: the top of the conversation is maxScrollExtent.
    if (pos.pixels > pos.maxScrollExtent - 400) unawaited(_loadOlder());
    _scheduleMarkRead();
  }

  void _scheduleMarkRead() {
    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 300), () {
      if (_messages.isEmpty) return;
      _markReadUpTo(_messages.last.timestamp);
    });
  }

  void _scrollToBottomIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _scrollController.offset > 0) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _markReadUpTo(int readTimestamp) async {
    final uid = _currentUid;
    final cid = _chatId;
    if (uid == null || cid == null) return;
    final remainingUnread = _messages
        .where((m) => m.timestamp > readTimestamp && m.senderId != uid)
        .length;
    await FirebaseDatabase.instance.ref('userChats/$uid/$cid').update({
      'unread': remainingUnread,
      'lastReadTimestamp': readTimestamp,
    });
  }

  /// A new relay key for a message in this chat (also its local id).
  String _newMessageId(String cid) =>
      FirebaseDatabase.instance.ref('privateChats/$cid/messages').push().key!;

  /// Shows [message] at once (saved locally as pending), then uploads it in
  /// the background; the tick updates when it reaches the server and again
  /// when the other phone receives it. Offline, it waits in the outbox.
  Future<void> _sendLocalFirst(String cid, PrivateMessage message,
      {String? preview}) async {
    await LocalChatStore.instance
        .insert(cid, message.copyWith(status: MessageStatus.pending));
    _scrollToBottomIfNeeded();
    unawaited(ChatSyncService.instance.send(
      chatId: cid,
      otherUid: _otherUid,
      message: message,
      preview: preview,
    ));
  }

  Future<void> _sendMessage() async {
    final trimmed = _messageController.text.trim();
    final uid = _currentUid;
    final cid = _chatId;
    if (trimmed.isEmpty) return;
    if (uid == null || cid == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Chat not ready yet — signing in… try again in a moment.')),
        );
      }
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final reply = _replyingTo;

    final message = PrivateMessage(
      id: _newMessageId(cid),
      text: trimmed,
      type: 'text',
      timestamp: timestamp,
      senderId: uid,
      senderName: _currentSenderName,
      senderPhone: _currentSenderPhone,
      replyToId: reply?.id ?? '',
      replyToText: reply != null ? previewLabelFor(reply) : '',
      replyToSenderName: reply?.senderName ?? '',
    );

    // Clear the input NOW — synchronously, before any await — so it empties
    // the instant Send is tapped regardless of network/db latency. The
    // Firebase/summary writes below used to run first, leaving the typed
    // text sitting there for seconds on a slow or offline connection.
    _messageController.clear();
    setState(() => _replyingTo = null);

    // Local store first (pending tick), upload in the background.
    await _sendLocalFirst(cid, message);
  }

  /// Send a picked attachment.
  ///
  /// Pass [filePath] on native (the picker copies the pick to a real cache
  /// file — even for `content://` picks) or [bytes] on web. Media
  /// (image/video/audio) streams straight to Cloudinary from disk via
  /// `MultipartFile.fromFile`, so a large video is never loaded whole into
  /// memory (the old `readAsBytes()` path OOM'd / threw silently). Generic
  /// files stay inline as base64 with a hard size cap.
  Future<void> _uploadAttachment({
    String? filePath,
    List<int>? bytes,
    required String fileName,
    required String? providedMime,
  }) async {
    final uid = _currentUid;
    final cid = _chatId;
    if (uid == null || cid == null) {
      _snack('Chat not ready yet — try again in a moment.');
      return;
    }
    if (filePath == null && (bytes == null || bytes.isEmpty)) {
      _snack("Couldn't read that file — try a different one.");
      return;
    }

    final mimeType = resolveMimeType(providedMime, fileName);
    final msgType = attachmentTypeFromMime(mimeType);

    // Media (image/video/audio) is uploaded to Cloudinary so the
    // recipient streams and resumes the download; generic files stay
    // inline in the message and keep the small size cap.
    final useCloudinary =
        msgType == 'image' || msgType == 'video' || msgType == 'audio';

    if (!useCloudinary) {
      // Read (and size-gate) the generic file from its path so we never
      // depend on the picker having handed us `withData` bytes.
      bytes ??= await _readFileCapped(filePath!, maxAttachmentBytes);
      if (bytes == null) {
        _snack(
            'That file is too large to send (max ${maxAttachmentBytes ~/ 1000000}MB).');
        return;
      }
    }

    setState(() => _isUploadingAttachment = true);
    final reply = _replyingTo;

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      String fileRef;
      if (useCloudinary) {
        String? uploadedUrl;
        String? uploadError;
        await uploadToCloudinary(
          filePath: filePath,
          fileBytes: filePath == null ? bytes : null,
          fileName: fileName,
          resourceType: cloudinaryResourceTypeForMime(mimeType),
          folder: CloudinaryConfig.chatMediaFolder,
          onSuccess: (u) => uploadedUrl = u,
          onError: (e) => uploadError = e,
        );
        if (uploadedUrl == null) {
          throw Exception(uploadError ?? 'Upload failed');
        }
        fileRef = uploadedUrl!;
      } else {
        fileRef = base64Encode(bytes!);
      }

      final message = PrivateMessage(
        id: _newMessageId(cid),
        type: msgType,
        fileUrl: fileRef,
        fileName: fileName,
        mimeType: mimeType,
        timestamp: timestamp,
        senderId: uid,
        senderName: _currentSenderName,
        senderPhone: _currentSenderPhone,
        replyToId: reply?.id ?? '',
        replyToText: reply != null ? previewLabelFor(reply) : '',
        replyToSenderName: reply?.senderName ?? '',
      );

      final label = switch (msgType) {
        'image' => '📷 Photo',
        'video' => '🎥 Video',
        'audio' => '🎵 Audio',
        _ => '📎 $fileName',
      };

      // The media is uploaded; the message itself goes local-first like
      // text, so it survives going offline from here on.
      await _sendLocalFirst(cid, message, preview: label);
      if (mounted) setState(() => _replyingTo = null);
    } catch (e) {
      _snack('Upload failed — check your connection and try again.');
      debugPrint('_uploadAttachment failed: $e');
    } finally {
      if (mounted) setState(() => _isUploadingAttachment = false);
    }
  }

  /// Reads [path] into memory only if it's within [cap] bytes; returns null
  /// (so the caller can show a "too large" message) otherwise, or on any
  /// read error.
  Future<List<int>?> _readFileCapped(String path, int cap) async {
    try {
      final f = File(path);
      if (await f.length() > cap) return null;
      return await f.readAsBytes();
    } catch (e) {
      debugPrint('_readFileCapped($path) failed: $e');
      return null;
    }
  }

  // ── Long-press actions, selection, copy, delete, share ─────────────
  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  List<PrivateMessage> get _selectedMessages =>
      _messages.where((m) => _selectedIds.contains(m.id)).toList();

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<Uint8List?> _imageBytesOf(PrivateMessage m) async {
    if (m.fileUrl.isEmpty) return null;
    if (m.fileUrl.startsWith('http')) {
      try {
        final res = await Dio().get<List<int>>(
          m.fileUrl,
          options: Options(responseType: ResponseType.bytes),
        );
        final data = res.data;
        return data == null ? null : Uint8List.fromList(data);
      } catch (_) {
        return null;
      }
    }
    try {
      return base64Decode(m.fileUrl);
    } catch (_) {
      return null;
    }
  }

  /// WhatsApp-style popup shown on a single-message long-press.
  Future<void> _showMessageActions(
      PrivateMessage message, Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'reply', child: Text('Reply')),
        if (_canCopyOne(message))
          const PopupMenuItem(value: 'copy', child: Text('Copy')),
        const PopupMenuItem(value: 'share', child: Text('Share')),
        const PopupMenuItem(value: 'delete', child: Text('Delete for me')),
        const PopupMenuItem(value: 'select', child: Text('Select')),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case 'reply':
        setState(() => _replyingTo = message);
        break;
      case 'copy':
        await _copyOne(message);
        break;
      case 'share':
        await _shareMessage(message);
        break;
      case 'delete':
        await _deleteForMe([message]);
        break;
      case 'select':
        _toggleSelected(message.id);
        break;
    }
  }

  bool _canCopyOne(PrivateMessage m) {
    if (m.type == 'text' && m.text.trim().isNotEmpty) return true;
    if (m.type == 'image') return true;
    if (m.type == 'video' && m.fileUrl.startsWith('http')) return true;
    return false;
  }

  Future<void> _copyOne(PrivateMessage m) async {
    if (m.type == 'text') {
      await Clipboard.setData(ClipboardData(text: m.text));
      _snack('Copied');
      return;
    }
    if (m.type == 'image') {
      final bytes = await _imageBytesOf(m);
      if (bytes != null) {
        await Pasteboard.writeImage(bytes);
        _snack('Image copied');
        return;
      }
    }
    if (m.type == 'video' && m.fileUrl.startsWith('http')) {
      await Clipboard.setData(ClipboardData(text: m.fileUrl));
      _snack('Video link copied');
      return;
    }
    _snack("Can't copy that");
  }

  /// Bulk copy from selection mode — concatenates text messages.
  Future<void> _copySelection() async {
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    if (selected.length == 1) {
      await _copyOne(selected.first);
      _clearSelection();
      return;
    }
    final texts = selected
        .where((m) => m.type == 'text' && m.text.trim().isNotEmpty)
        .map((m) => m.text.trim())
        .toList();
    if (texts.isEmpty) {
      _snack('Select text messages to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: texts.join('\n')));
    _clearSelection();
    _snack('Copied');
  }

  bool get _canCopySelection => _selectedMessages.any((m) => _canCopyOne(m));

  Future<void> _shareMessage(PrivateMessage m) async {
    switch (m.type) {
      case 'text':
        await ShareService.instance.shareText(m.text);
        break;
      case 'image':
        if (m.fileUrl.startsWith('http')) {
          await ShareService.instance.shareImage(url: m.fileUrl);
        } else {
          final bytes = await _imageBytesOf(m);
          await ShareService.instance.shareImage(bytes: bytes);
        }
        break;
      case 'video':
        final isRemote = m.fileUrl.startsWith('http');
        if (isRemote &&
            await ResumableDownloader.instance.completedFile(m.id, '.mp4') ==
                null) {
          _snack('Preparing video to share…');
        }
        await ShareService.instance.shareVideo(
          title: '',
          cacheKey: isRemote ? m.id : null,
          remoteUrl: isRemote ? m.fileUrl : null,
        );
        break;
      default:
        await ShareService.instance.shareApp();
    }
  }

  Future<void> _deleteForMe(List<PrivateMessage> msgs) async {
    final cid = _chatId;
    if (cid == null || msgs.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msgs.length == 1
            ? 'Delete this message from this device?'
            : 'Delete ${msgs.length} messages from this device?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete for me')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final m in msgs) {
      await LocalChatStore.instance.deleteForMe(cid, m.id);
    }
    _clearSelection();
  }

  Future<void> _pickImageVideo() async {
    setState(() => _showAttachMenu = false);
    try {
      final XFile? file = await ImagePicker().pickMedia();
      if (file == null) return;
      if (kIsWeb) {
        await _uploadAttachment(
            bytes: await file.readAsBytes(),
            fileName: file.name,
            providedMime: file.mimeType);
      } else {
        // Hand the picker's cache-file path straight through — never read a
        // (potentially huge) video into memory here.
        await _uploadAttachment(
            filePath: file.path,
            fileName: file.name,
            providedMime: file.mimeType);
      }
    } catch (e) {
      debugPrint('_pickImageVideo failed: $e');
      _snack("Couldn't attach that — try again.");
    }
  }

  Future<void> _pickAudio() async {
    setState(() => _showAttachMenu = false);
    await _pickViaFilePicker(FileType.audio);
  }

  Future<void> _pickFile() async {
    setState(() => _showAttachMenu = false);
    await _pickViaFilePicker(FileType.any);
  }

  Future<void> _pickViaFilePicker(FileType type) async {
    try {
      // `withData` only on web — on native it forces the whole file into
      // memory, and without a path the old code silently bailed on
      // `picked.bytes == null` (the audio-attachment bug).
      final result = await FilePicker.platform.pickFiles(
        type: type,
        withData: kIsWeb,
      );
      final files = result?.files ?? const [];
      if (files.isEmpty) return;
      final picked = files.first;

      if (kIsWeb) {
        if (picked.bytes == null) {
          _snack("Couldn't read that file — try a different one.");
          return;
        }
        await _uploadAttachment(
            bytes: picked.bytes, fileName: picked.name, providedMime: null);
      } else {
        if (picked.path == null) {
          _snack("Couldn't read that file — try a different one.");
          return;
        }
        await _uploadAttachment(
            filePath: picked.path, fileName: picked.name, providedMime: null);
      }
    } catch (e) {
      debugPrint('_pickViaFilePicker($type) failed: $e');
      _snack("Couldn't attach that — try again.");
    }
  }

  Future<void> _startVoiceRecording() async {
    setState(() {
      _recordingSeconds = 0;
      _isPaused = false;
      _isRecording = true;
    });
    await _voiceRecorder.startRecording();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isPaused && mounted) setState(() => _recordingSeconds++);
    });
  }

  Future<void> _togglePauseRecording() async {
    if (_isPaused) {
      await _voiceRecorder.resumeRecording();
    } else {
      await _voiceRecorder.pauseRecording();
    }
    setState(() => _isPaused = !_isPaused);
  }

  Future<void> _cancelVoiceRecording() async {
    _recordingTimer?.cancel();
    setState(() {
      _isRecording = false;
      _isPaused = false;
      _recordingSeconds = 0;
    });
    await _voiceRecorder.cancelRecording();
  }

  Future<void> _stopVoiceRecordingAndSend() async {
    final uid = _currentUid;
    final cid = _chatId;
    _recordingTimer?.cancel();

    final durationSeconds = await _voiceRecorder.stopRecording();
    setState(() {
      _isRecording = false;
      _isPaused = false;
    });

    if (uid == null || cid == null) {
      await _voiceRecorder.cancelRecording();
      return;
    }

    final reply = _replyingTo;
    await _voiceRecorder.encodeRecordingToBase64(
      onSuccess: (base64Audio) async {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final message = PrivateMessage(
          id: _newMessageId(cid),
          audioUrl: base64Audio,
          type: 'voice',
          // VoiceRecorderService always emits a PCM-16 WAV; state it
          // explicitly so playback never has to guess the container.
          mimeType: 'audio/wav',
          duration: durationSeconds,
          waveform: _voiceRecorder.lastWaveform,
          timestamp: timestamp,
          senderId: uid,
          senderName: _currentSenderName,
          senderPhone: _currentSenderPhone,
          replyToId: reply?.id ?? '',
          replyToText: reply != null ? previewLabelFor(reply) : '',
          replyToSenderName: reply?.senderName ?? '',
        );
        if (mounted) setState(() => _replyingTo = null);
        await _sendLocalFirst(cid, message, preview: '🎤 Voice message');
      },
      onFailure: (_) {},
    );
  }

  // ── LIVE CALL METHOD ──
  Future<void> _startCall(String callType) async {
    final profile = _currentProfile;
    if (profile == null || _chatId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Chat not ready yet — try again in a moment.')),
      );
      return;
    }

    await startPrivateAppCall(
      context: context,
      caller: profile,
      calleeUid: _otherUid,
      calleeName: _otherUserName.isEmpty ? 'Chat' : _otherUserName,
      callType: callType,
    );
  }
  // ──────────────────────

  void _showStickerPickerSheet() {
    const stickers = [
      '👍',
      '❤️',
      '😂',
      '🙏',
      '🔥',
      '🎉',
      '👏',
      '😮',
      '😢',
      '🎶'
    ];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: stickers
                .map((s) => InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.pop(context);
                        _sendSticker(s);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(s, style: const TextStyle(fontSize: 28)),
                      ),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _sendSticker(String stickerId) async {
    final uid = _currentUid;
    final cid = _chatId;
    if (uid == null || cid == null) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final reply = _replyingTo;
    final message = PrivateMessage(
      id: _newMessageId(cid),
      type: 'sticker',
      stickerId: stickerId,
      timestamp: timestamp,
      senderId: uid,
      senderName: _currentSenderName,
      senderPhone: _currentSenderPhone,
      replyToId: reply?.id ?? '',
      replyToText: reply != null ? previewLabelFor(reply) : '',
      replyToSenderName: reply?.senderName ?? '',
    );
    setState(() => _replyingTo = null);
    await _sendLocalFirst(cid, message, preview: '🩹 Sticker');
  }

  String _formatLastSeen(int millis) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - millis;
    const oneDay = 24 * 60 * 60 * 1000;
    if (diff < oneDay) {
      final d = DateTime.fromMillisecondsSinceEpoch(millis);
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      final m = d.minute.toString().padLeft(2, '0');
      final ampm = d.hour >= 12 ? 'PM' : 'AM';
      return 'today at $h:$m $ampm';
    } else if (diff < 2 * oneDay) {
      return 'yesterday';
    }
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${d.month}/${d.day}';
  }

  @override
  void dispose() {
    _localSub?.cancel();
    _presenceSub?.cancel();
    _readReceiptSub?.cancel();
    _markReadDebounce?.cancel();
    _recordingTimer?.cancel();
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Widget _buildMessageRow(BuildContext context, int index) {
    final message = _messages[index];
    final isMine = message.senderId == _currentUid;
    final selected = _selectedIds.contains(message.id);
    final palette = ChatTheme.of(context);

    final showDivider = index == 0 ||
        !isSameDay(
          DateTime.fromMillisecondsSinceEpoch(_messages[index - 1].timestamp),
          DateTime.fromMillisecondsSinceEpoch(message.timestamp),
        );

    Widget content;
    switch (message.type) {
      case 'voice':
        content = VoiceMessageBubble(
          message: message,
          isMine: isMine,
          onListened: () {
            final cid = _chatId;
            if (cid != null && !message.listened) {
              LocalChatStore.instance.markListened(cid, message.id);
            }
          },
        );
        break;
      case 'image':
        content = ImageMessageBubble(fileUrl: message.fileUrl);
        break;
      case 'video':
        content = VideoMessageBubble(
          messageId: message.id,
          fileUrl: message.fileUrl,
          mimeType: message.mimeType,
          isMine: isMine,
        );
        break;
      case 'audio':
        content = AudioAttachmentBubble(
          messageId: message.id,
          fileUrl: message.fileUrl,
          fileName: message.fileName,
          mimeType: message.mimeType,
          isMine: isMine,
          durationSeconds: message.duration,
        );
        break;
      case 'file':
        content = message.mimeType.startsWith('image/')
            ? ImageMessageBubble(fileUrl: message.fileUrl)
            : FileMessageBubble(
                fileUrl: message.fileUrl,
                fileName: message.fileName,
                mimeType: message.mimeType,
                isMine: isMine,
              );
        break;
      case 'call':
        final isVideo = message.text.contains('video');
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo ? Icons.videocam_off_outlined : Icons.call_missed,
              size: 18,
              color: isMine ? palette.outgoingText : palette.missedCall,
            ),
            const SizedBox(width: 8),
            Text(
              isVideo ? 'Missed video call' : 'Missed voice call',
              style: TextStyle(color: palette.text(isMine), fontSize: 14),
            ),
          ],
        );
        break;
      default:
        content = LinkifiedText(
          message.text,
          style:
              TextStyle(color: palette.text(isMine), fontSize: 15, height: 1.3),
          linkColor: palette.link(isMine),
        );
    }

    // Time + tick: inside the bubble (bottom right), or under a sticker.
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          messageClock(message.timestamp),
          style: TextStyle(
              fontSize: 10.5,
              color: message.type == 'sticker'
                  ? palette.chipText
                  : palette.meta(isMine)),
        ),
        if (isMine) ...[
          const SizedBox(width: 4),
          MessageStatusTick(
            status: message.status,
            isRead: _otherUserLastReadTimestamp >= message.timestamp,
            color: message.type == 'sticker'
                ? palette.chipText
                : palette.outgoingMeta,
            readColor: message.type == 'sticker'
                ? palette.incomingLink
                : palette.readTick,
          ),
        ],
      ],
    );

    final bubble = GestureDetector(
      onLongPressStart: (details) {
        if (_selectionMode) {
          _toggleSelected(message.id);
        } else {
          _showMessageActions(message, details.globalPosition);
        }
      },
      onTap: () {
        if (_selectionMode) _toggleSelected(message.id);
      },
      child: Container(
        color: selected
            ? palette.outgoing.withValues(alpha: 0.18)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 4),
        // While selecting, swallow taps inside the bubble (image preview,
        // video open, audio play) so a tap toggles selection instead.
        child: AbsorbPointer(
          absorbing: _selectionMode,
          child: Column(
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment:
                    isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_selectionMode) ...[
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: selected ? palette.outgoing : palette.incomingMeta,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (!isMine) ...[
                    AvatarView(
                        photoBase64: _otherUserPhotoBase64,
                        displayName: _otherUserName,
                        size: 28),
                    const SizedBox(width: 6),
                  ],
                  if (message.type == 'sticker')
                    Column(
                      crossAxisAlignment: isMine
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        ReplyQuotePreview(
                            message: message,
                            isMine: isMine,
                            senderLabel: _replySenderLabel(message)),
                        StickerMessageBubble(stickerId: message.stickerId),
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: palette.chip,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: meta,
                        ),
                      ],
                    )
                  else
                    Flexible(
                      child: Container(
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.8),
                        padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
                        decoration: BoxDecoration(
                          color: palette.bubble(isMine),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMine ? 16 : 4),
                            bottomRight: Radius.circular(isMine ? 4 : 16),
                          ),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 2,
                                offset: Offset(0, 1)),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ReplyQuotePreview(
                                message: message,
                                isMine: isMine,
                                senderLabel: _replySenderLabel(message)),
                            content,
                            const SizedBox(height: 3),
                            Align(
                                alignment: Alignment.bottomRight, child: meta),
                          ],
                        ),
                      ),
                    ),
                  if (isMine) ...[
                    const SizedBox(width: 6),
                    AvatarView(
                        photoBase64: _currentSenderPhotoUrl,
                        displayName: _currentSenderName,
                        size: 28),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (!showDivider) return bubble;
    return Column(
      children: [
        _DateDivider(label: dateDividerLabel(message.timestamp)),
        bubble,
      ],
    );
  }

  /// Friendly country name for a stored ISO code (e.g. "SL" → "Sierra
  /// Leone"). Falls back to whatever was stored if it isn't a known ISO.
  String _countryLabel(String iso) {
    if (iso.trim().isEmpty) return '';
    final match = countries
        .where((c) => c.code.toUpperCase() == iso.trim().toUpperCase());
    if (match.isEmpty) return iso.trim();
    final c = match.first;
    return '${c.flag}  ${c.name}';
  }

  void _showOtherPhotoFullScreen() {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      pageBuilder: (ctx, __, ___) => FullScreenProfilePhoto(
        name: _otherUserName.isEmpty ? 'Chat' : _otherUserName,
        photoUrl: _otherUserPhotoBase64,
        isOwnProfile: false,
        onDismiss: () => Navigator.pop(ctx),
      ),
    );
  }

  /// Tapping the name/photo in the app bar opens the other person's
  /// account card: their photo, name, number and country.
  void _showOtherUserProfile() {
    final country = _countryLabel(_otherUserCountry);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _otherUserPhotoBase64.isEmpty
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _showOtherPhotoFullScreen();
                      },
                child: AvatarView(
                  photoBase64: _otherUserPhotoBase64,
                  displayName: _otherUserName,
                  size: 96,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _otherUserName.isEmpty ? 'Chat' : _otherUserName,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold, color: _kBrand),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              _profileInfoRow(
                Icons.phone,
                _otherUserPhone.isEmpty
                    ? 'Number not available'
                    : formatPhoneForDisplay(_otherUserPhone),
              ),
              if (country.isNotEmpty) ...[
                const SizedBox(height: 12),
                _profileInfoRow(Icons.public, country),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileInfoRow(IconData icon, String value) {
    return Row(
      children: [
        Icon(icon, size: 20, color: _kBrand),
        const SizedBox(width: 14),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 15)),
        ),
      ],
    );
  }

  /// Who a quoted reply came from, under the contact naming rule. Replies
  /// only record the original sender's own profile name, and a 1:1 chat has
  /// two people — so it's "You" if that's my name, otherwise the other
  /// person.
  String _replySenderLabel(PrivateMessage message) {
    final name = message.replyToSenderName;
    if (name.isEmpty) return '';
    if (name == _currentSenderName) return 'You';
    return _otherUserName;
  }

  PreferredSizeWidget _chatAppBar() {
    return AppBar(
      backgroundColor: _kBrand,
      foregroundColor: Colors.white,
      titleSpacing: 0,
      title: InkWell(
        onTap: _showOtherUserProfile,
        child: Row(
          children: [
            AvatarView(
                photoBase64: _otherUserPhotoBase64,
                displayName: _otherUserName,
                size: 34),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _otherUserName.isEmpty ? 'Chat' : _otherUserName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_otherUserOnline)
                    const Text('Online',
                        style: TextStyle(fontSize: 11, color: Colors.white70))
                  else if (_otherUserLastSeen > 0)
                    Text(
                      'Last seen ${_formatLastSeen(_otherUserLastSeen)}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
            icon: const Icon(Icons.call), onPressed: () => _startCall('audio')),
        IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () => _startCall('video')),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    final single = _selectedIds.length == 1;
    return AppBar(
      backgroundColor: _kBrand,
      foregroundColor: Colors.white,
      leading:
          IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        if (single)
          IconButton(
            icon: const Icon(Icons.reply),
            tooltip: 'Reply',
            onPressed: () {
              setState(() {
                _replyingTo = _selectedMessages.first;
                _selectedIds.clear();
              });
            },
          ),
        if (_canCopySelection)
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy',
            onPressed: _copySelection,
          ),
        if (single)
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share',
            onPressed: () {
              final m = _selectedMessages.first;
              _clearSelection();
              _shareMessage(m);
            },
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete for me',
          onPressed: () => _deleteForMe(_selectedMessages),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when a contact sync renames the other person.
    context.watch<DisplayNames>();
    // "Morning Lilac" — follows the phone's light/dark setting.
    final palette =
        ChatPalette.forBrightness(MediaQuery.platformBrightnessOf(context));
    return ChatTheme(
      palette: palette,
      child: Scaffold(
        backgroundColor: palette.background,
        // Explicit (matches the default) — the body, including the input
        // bar below, resizes correctly above the keyboard this way.
        resizeToAvoidBottomInset: true,
        appBar: _selectionMode ? _selectionAppBar() : _chatAppBar(),
        // NOTE: input bar moved out of `bottomNavigationBar` and into the
        // body's Column below. bottomNavigationBar does not reliably track
        // the keyboard inset — especially when its own height changes
        // dynamically (reply preview / upload bar / recording bar / attach
        // menu), which was hiding the bar behind the keyboard.
        body: ChatBackground(
          palette: palette,
          child: Column(
            children: [
              Expanded(
                // Reversed: item 0 is the newest message at the bottom, so the
                // chat opens on it immediately; older pages are prepended as
                // the top is approached (see _onScroll / _loadOlder).
                child: ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) =>
                      _buildMessageRow(context, _messages.length - 1 - i),
                ),
              ),
              // ✅ Input bar now lives in the body, below the message list,
              // so it moves correctly with the keyboard.
              PrivateChatInputBar(
                isUploadingAttachment: _isUploadingAttachment,
                replyingTo: _replyingTo,
                replyingToName: _replyingTo == null
                    ? ''
                    : (_replyingTo!.senderId == _currentUid
                        ? 'yourself'
                        : _otherUserName),
                onCancelReply: () => setState(() => _replyingTo = null),
                isRecording: _isRecording,
                isPaused: _isPaused,
                recordingSeconds: _recordingSeconds,
                onCancelRecording: _cancelVoiceRecording,
                liveWaveform: _voiceRecorder.liveWaveform,
                onTogglePauseRecording: _togglePauseRecording,
                onStopRecordingAndSend: _stopVoiceRecordingAndSend,
                onStartRecording: _startVoiceRecording,
                controller: _messageController,
                onMessageInputChange: (v) => setState(() {}),
                onSendMessage: _sendMessage,
                showAttachMenu: _showAttachMenu,
                onShowAttachMenuChange: (v) =>
                    setState(() => _showAttachMenu = v),
                onPickImageVideo: _pickImageVideo,
                onPickAudio: _pickAudio,
                onPickFile: _pickFile,
                onShowStickerPicker: _showStickerPickerSheet,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateDivider extends StatelessWidget {
  final String label;
  const _DateDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    final palette = ChatTheme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: palette.chip,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 11.5,
              color: palette.chipText,
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
