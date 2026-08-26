import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../auth/auth_manager.dart';
import '../../data/chat_summary.dart';
import '../../data/chat_read_position_store.dart';
import '../../data/local_chat_store.dart';
import '../../data/private_message.dart';
import 'chat_helpers.dart';
import 'message_bubbles.dart' hide VoiceMessageBubble;
import '../../services/voice_message_bubble.dart';
import '../chat/private_chat_input.dart';
import 'private_chat_push.dart';
import 'package:tbtrapp/services/voice_recorder.dart';
import 'package:tbtrapp/services/recording_foreground_service.dart';

// ── CALL IMPORTS ──
import '../../calls/call_initiator.dart';
import '../../navigation/call_navigator.dart';
// ──────────────────

const _kBrand = Color(0xFF102A72);

class PrivateChatScreen extends StatefulWidget {
  final String otherUid;
  const PrivateChatScreen({super.key, required this.otherUid});

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> {
  String? _currentUid;
  String _currentSenderName = '';
  String _currentSenderPhone = '';
  String _currentSenderPhotoUrl = '';

  String _otherUserName = '';
  String _otherUserPhotoBase64 = '';
  bool _otherUserOnline = false;
  int _otherUserLastSeen = 0;
  int _otherUserLastReadTimestamp = 0;

  String? _chatId;
  DatabaseReference? _messagesRef;

  final List<PrivateMessage> _messages = [];
  final _scrollController = ScrollController();
  final _messageController = TextEditingController();

  StreamSubscription<List<PrivateMessage>>? _localSub;
  StreamSubscription<DatabaseEvent>? _relaySub;
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
  String? _longPressMessageId;

  @override
  void initState() {
    super.initState();
    _init();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _init() async {
    final cached = await AuthManager.getCachedProfile();
    if (cached != null) {
      _currentUid = cached.uid;
      _currentSenderName = cached.name;
      _currentSenderPhone = cached.phone;
      _currentSenderPhotoUrl = cached.photoUrl;

      _chatId = privateChatId(_currentUid!, widget.otherUid);
      _messagesRef = FirebaseDatabase.instance.ref('privateChats/${_chatId!}/messages');

      _listenLocalMessages();
      _listenRelay();
      _listenReadReceipt();

      if (mounted) setState(() {});
    } else {
      debugPrint('PrivateChatScreen: no cached profile found — user may not have completed signup.');
    }

    await AuthManager.ensureSignedIn(
      onReady: () {},
      onError: (msg) => debugPrint('AuthManager.ensureSignedIn failed: $msg'),
    );

    _listenOtherUserProfile();
    _listenPresence();
  }

  void _listenOtherUserProfile() {
    FirebaseDatabase.instance.ref('users/${widget.otherUid}').get().then((snap) {
      final val = snap.value;
      if (val is Map) {
        final name = (val['name'] ?? '') as String;
        final phone = (val['phone'] ?? '') as String;
        setState(() {
          _otherUserName = name.isNotEmpty ? name : phone;
          _otherUserPhotoBase64 = (val['photoUrl'] ?? '') as String;
        });
      } else {
        setState(() => _otherUserName = 'Chat');
      }
    }).catchError((_) {
      setState(() => _otherUserName = 'Chat');
    });
  }

  void _listenPresence() {
    _presenceSub = FirebaseDatabase.instance
        .ref('presence/${widget.otherUid}')
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
        .ref('userChats/${widget.otherUid}/$cid/lastReadTimestamp')
        .onValue
        .listen((event) {
      final v = event.snapshot.value;
      setState(() => _otherUserLastReadTimestamp = (v as num?)?.toInt() ?? 0);
    });
  }

  void _listenLocalMessages() {
    final cid = _chatId;
    if (cid == null) return;
    _localSub = LocalChatStore.instance.observeMessages(cid).listen((msgs) async {
      final wasEmpty = _messages.isEmpty;
      setState(() {
        _messages
          ..clear()
          ..addAll(msgs);
      });
      if (wasEmpty && msgs.isNotEmpty) {
        final restored = await _restoreScrollPosition();
        if (!restored) {
          _scrollToBottomIfNeeded();
        }
      } else {
        _scrollToBottomIfNeeded();
      }
    });
  }

  Future<bool> _restoreScrollPosition() async {
    final cid = _chatId;
    if (cid == null || _messages.isEmpty) return false;
    final lastReadId = await ChatReadPositionStore.instance.getLastRead(cid);
    if (lastReadId == null) return false;
    final index = _messages.indexWhere((m) => m.id == lastReadId);
    if (index == -1) return false;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final estimatedOffset = index * 72.0;
      _scrollController.jumpTo(
        estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
    return true;
  }

  Future<void> _saveScrollPosition() async {
    final cid = _chatId;
    if (cid == null || _messages.isEmpty || !_scrollController.hasClients) return;
    final index = (_scrollController.offset / 72.0).round().clamp(0, _messages.length - 1);
    await ChatReadPositionStore.instance.saveLastRead(cid, _messages[index].id);
  }

  void _listenRelay() {
    final ref = _messagesRef;
    final cid = _chatId;
    final myUid = _currentUid;
    if (ref == null || cid == null) return;

    _relaySub = ref.onChildAdded.listen((event) async {
      final key = event.snapshot.key;
      final val = event.snapshot.value;
      if (key == null || val is! Map) return;

      final msg = PrivateMessage.fromFirebaseMap(key, val);
      await LocalChatStore.instance.insert(cid, msg);

      if (myUid != null && msg.senderId != myUid) {
        await event.snapshot.ref.remove();
      }
    });
  }

  void _onScroll() {
    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 300), () {
      if (_messages.isEmpty) return;
      _markReadUpTo(_messages.last.timestamp);
    });
  }

  void _scrollToBottomIfNeeded() {
    Future.delayed(const Duration(milliseconds: 200), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
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

  Future<void> _writeChatSummaries(String uid, String cid, String lastMessage, int timestamp) async {
    final db = FirebaseDatabase.instance;

    await db.ref('userChats/$uid/$cid').set(
      ChatSummary(
        chatId: cid,
        otherUid: widget.otherUid,
        otherName: _otherUserName.isEmpty ? 'Chat' : _otherUserName,
        otherPhotoUrl: _otherUserPhotoBase64,
        lastMessage: lastMessage,
        lastTimestamp: timestamp,
        unread: 0,
        lastReadTimestamp: timestamp,
      ).toFirebaseMap(),
    );

    final recipientRef = db.ref('userChats/${widget.otherUid}/$cid');
    await recipientRef.update({
      'otherUid': uid,
      'otherName': _currentSenderName.isEmpty ? _currentSenderPhone : _currentSenderName,
      'otherPhotoUrl': _currentSenderPhotoUrl,
      'lastMessage': lastMessage,
      'lastTimestamp': timestamp,
    });

    await recipientRef.child('unread').runTransaction((current) {
      final currentInt = (current as num?)?.toInt() ?? 0;
      return Transaction.success(currentInt + 1);
    });
  }

  Future<void> _sendMessage() async {
    final trimmed = _messageController.text.trim();
    final uid = _currentUid;
    final ref = _messagesRef;
    final cid = _chatId;
    if (trimmed.isEmpty) return;
    if (uid == null || ref == null || cid == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat not ready yet — signing in… try again in a moment.')),
        );
      }
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final reply = _replyingTo;
    final newRef = ref.push();

    final message = PrivateMessage(
      id: newRef.key ?? '',
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

    // Clear input + reply state immediately, before the RTDB round-trips
    // below — previously this happened only after both awaits resolved,
    // so the typed text sat visible in the field for as long as the
    // network write took (most noticeable on web).
    _messageController.clear();
    setState(() => _replyingTo = null);

    await newRef.set(message.toFirebaseMap());
    await LocalChatStore.instance.insert(cid, message);

    unawaited(sendPrivateChatPushNotification(
      otherUid: widget.otherUid,
      chatId: cid,
      senderName: _currentSenderName,
      messageBody: trimmed,
      senderUid: uid,
    ));

    await _writeChatSummaries(uid, cid, trimmed, timestamp);

    _scrollToBottomIfNeeded();
  }

  Future<void> _uploadAttachment({
    required List<int> bytes,
    required String fileName,
    required String? providedMime,
  }) async {
    final uid = _currentUid;
    final ref = _messagesRef;
    final cid = _chatId;
    if (uid == null || ref == null || cid == null) return;

    final mimeType = resolveMimeType(providedMime, fileName);
    final msgType = attachmentTypeFromMime(mimeType);
    final sizeLimit = (msgType == 'video' || msgType == 'audio') ? maxVideoAudioBytes : maxAttachmentBytes;

    if (bytes.length > sizeLimit) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('That file is too large to send (max ${sizeLimit ~/ 1000000}MB).')),
        );
      }
      return;
    }

    setState(() => _isUploadingAttachment = true);
    final reply = _replyingTo;

    try {
      final base64Data = base64Encode(bytes);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final newRef = ref.push();

      final message = PrivateMessage(
        id: newRef.key ?? '',
        type: msgType,
        fileUrl: base64Data,
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

      await newRef.set(message.toFirebaseMap());
      await LocalChatStore.instance.insert(cid, message);

      final label = switch (msgType) {
        'image' => '📷 Photo',
        'video' => '🎥 Video',
        'audio' => '🎵 Audio',
        _ => '📎 $fileName',
      };

      await _writeChatSummaries(uid, cid, label, timestamp);
      unawaited(sendPrivateChatPushNotification(
        otherUid: widget.otherUid,
        chatId: cid,
        senderName: _currentSenderName,
        messageBody: label,
        senderUid: uid,
      ));

      setState(() => _replyingTo = null);
      _scrollToBottomIfNeeded();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingAttachment = false);
    }
  }

  Future<void> _pickImageVideo() async {
    setState(() => _showAttachMenu = false);
    final picker = ImagePicker();
    final XFile? file = await picker.pickMedia();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _uploadAttachment(bytes: bytes, fileName: file.name, providedMime: file.mimeType);
  }
  Future<void> _pickAudio() async {
    setState(() => _showAttachMenu = false);
    final result = await FilePicker.pickFiles(type: FileType.audio);
    if (result.isEmpty) return;
    final picked = result.first;
    final bytes = await picked.readAsBytes();
    await _uploadAttachment(bytes: bytes, fileName: picked.name, providedMime: null);
  }

  Future<void> _pickFile() async {
    setState(() => _showAttachMenu = false);
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final picked = result.first;
    final bytes = await picked.readAsBytes();
    await _uploadAttachment(bytes: bytes, fileName: picked.name, providedMime: null);
  }

  Future<void> _startVoiceRecording() async {
    setState(() {
      _recordingSeconds = 0;
      _isPaused = false;
      _isRecording = true;
    });
    await _voiceRecorder.startRecording();
    // Android suspends microphone access when the app is backgrounded
    // unless a foreground service is actively running — without this, the
    // recording died the moment you left the app.
    await RecordingForegroundService.start();
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
    await RecordingForegroundService.stop();
  }

  Future<void> _stopVoiceRecordingAndSend() async {
    final uid = _currentUid;
    final ref = _messagesRef;
    final cid = _chatId;
    _recordingTimer?.cancel();

    final durationSeconds = await _voiceRecorder.stopRecording();
    setState(() {
      _isRecording = false;
      _isPaused = false;
    });
    await RecordingForegroundService.stop();

    if (uid == null || ref == null || cid == null) {
      await _voiceRecorder.cancelRecording();
      return;
    }

    final reply = _replyingTo;
    await _voiceRecorder.encodeRecordingToBase64(
      onSuccess: (base64Audio) async {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final newRef = ref.push();
        final message = PrivateMessage(
          id: newRef.key ?? '',
          audioUrl: base64Audio,
          type: 'voice',
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
        await newRef.set(message.toFirebaseMap());
        await LocalChatStore.instance.insert(cid, message);
        await _writeChatSummaries(uid, cid, '🎤 Voice message', timestamp);
        unawaited(sendPrivateChatPushNotification(
          otherUid: widget.otherUid,
          chatId: cid,
          senderName: _currentSenderName,
          messageBody: '🎤 Voice message',
          senderUid: uid,
        ));
        setState(() => _replyingTo = null);
        _scrollToBottomIfNeeded();
      },
      onFailure: (_) {},
    );
  }

  // ── LIVE CALL METHOD ──
  Future<void> _startCall(String callType) async {
    final uid = _currentUid;
    final cid = _chatId;
    if (uid == null || cid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat not ready yet — try again in a moment.')),
      );
      return;
    }

    final initiator = CallInitiator();
    await initiator.initiateCall(
      callerUid: uid,
      callerName: _currentSenderName,
      callerPhoto: _currentSenderPhotoUrl,
      calleeUid: widget.otherUid,
      chatId: cid,
      callType: callType,
      onCallIdReady: (callId) {
        CallNavigator.toOutgoingCall(
          callId: callId,
          calleeName: _otherUserName,
          callType: callType,
        );
      },
    );
  }
  // ──────────────────────

  void _showStickerPickerSheet() {
    const stickers = ['👍', '❤️', '😂', '🙏', '🔥', '🎉'];
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: stickers
              .map((s) => InkWell(
            onTap: () {
              Navigator.pop(context);
              _sendSticker(s);
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(s, style: const TextStyle(fontSize: 32)),
            ),
          ))
              .toList(),
        ),
      ),
    );
  }

  Future<void> _sendSticker(String stickerId) async {
    final uid = _currentUid;
    final ref = _messagesRef;
    final cid = _chatId;
    if (uid == null || ref == null || cid == null) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final reply = _replyingTo;
    final newRef = ref.push();
    final message = PrivateMessage(
      id: newRef.key ?? '',
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
    await newRef.set(message.toFirebaseMap());
    await LocalChatStore.instance.insert(cid, message);
    await _writeChatSummaries(uid, cid, '🩹 Sticker', timestamp);
    unawaited(sendPrivateChatPushNotification(
      otherUid: widget.otherUid,
      chatId: cid,
      senderName: _currentSenderName,
      messageBody: '🩹 Sticker',
      senderUid: uid,
    ));
    setState(() => _replyingTo = null);
    _scrollToBottomIfNeeded();
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
    _saveScrollPosition();
    _localSub?.cancel();
    _relaySub?.cancel();
    _presenceSub?.cancel();
    _readReceiptSub?.cancel();
    _markReadDebounce?.cancel();
    _recordingTimer?.cancel();
    // Safety net: leaving this screen mid-recording (e.g. back button)
    // shouldn't leave the mic-keepalive foreground service running forever.
    if (_isRecording) RecordingForegroundService.stop();
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Explicit (matches the default) — the body, including the input
      // bar below, resizes correctly above the keyboard this way.
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: _kBrand,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            AvatarView(photoBase64: _otherUserPhotoBase64, displayName: _otherUserName, size: 34),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _otherUserName.isEmpty ? 'Chat' : _otherUserName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_otherUserOnline)
                    const Text('Online', style: TextStyle(fontSize: 11, color: Colors.white70))
                  else if (_otherUserLastSeen > 0)
                    Text(
                      'Last seen ${_formatLastSeen(_otherUserLastSeen)}',
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // ── LIVE CALL BUTTONS ──
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () => _startCall('audio'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () => _startCall('video'),
          ),
          // ────────────────────────
        ],
      ),
      // NOTE: input bar moved out of `bottomNavigationBar` and into the
      // body's Column below. bottomNavigationBar does not reliably track
      // the keyboard inset — especially when its own height changes
      // dynamically (reply preview / upload bar / recording bar / attach
      // menu), which was hiding the bar behind the keyboard.
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF3F7FF), Colors.white],
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                itemCount: _messages.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  final isMine = message.senderId == _currentUid;

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
                      content = VideoMessageBubble(fileUrl: message.fileUrl, mimeType: message.mimeType, isMine: isMine);
                      break;
                    case 'audio':
                      content = AudioAttachmentBubble(fileUrl: message.fileUrl, fileName: message.fileName, isMine: isMine);
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
                    default:
                      content = Text(
                        message.text,
                        style: TextStyle(color: isMine ? Colors.white : const Color(0xFF1B1B1B), fontSize: 14),
                      );
                  }

                  return GestureDetector(
                    onLongPress: () => setState(() => _longPressMessageId = message.id),
                    child: Column(
                      crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (!isMine) ...[
                              AvatarView(photoBase64: _otherUserPhotoBase64, displayName: _otherUserName, size: 28),
                              const SizedBox(width: 6),
                            ],
                            if (message.type == 'sticker')
                              Column(
                                crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  ReplyQuotePreview(message: message, isMine: isMine),
                                  StickerMessageBubble(stickerId: message.stickerId),
                                ],
                              )
                            else
                              Flexible(
                                child: Container(
                                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isMine ? const Color(0xFF1565C0) : Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ReplyQuotePreview(message: message, isMine: isMine),
                                      content,
                                    ],
                                  ),
                                ),
                              ),
                            if (isMine) ...[
                              const SizedBox(width: 6),
                              AvatarView(photoBase64: _currentSenderPhotoUrl, displayName: _currentSenderName, size: 28),
                            ],
                          ],
                        ),
                        if (isMine)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, right: 4),
                            child: ReadReceiptTick(isRead: _otherUserLastReadTimestamp >= message.timestamp),
                          ),
                        if (_longPressMessageId == message.id)
                          Row(
                            mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.reply, size: 16),
                                label: const Text('Reply'),
                                onPressed: () => setState(() {
                                  _replyingTo = message;
                                  _longPressMessageId = null;
                                }),
                              ),
                              TextButton.icon(
                                icon: const Icon(Icons.emoji_emotions, size: 16),
                                label: const Text('Sticker'),
                                onPressed: () {
                                  setState(() => _longPressMessageId = null);
                                  _showStickerPickerSheet();
                                },
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // ✅ Input bar now lives in the body, below the message list,
            // so it moves correctly with the keyboard.
            PrivateChatInputBar(
              isUploadingAttachment: _isUploadingAttachment,
              replyingTo: _replyingTo,
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
              onShowAttachMenuChange: (v) => setState(() => _showAttachMenu = v),
              onPickImageVideo: _pickImageVideo,
              onPickAudio: _pickAudio,
              onPickFile: _pickFile,
              onShowStickerPicker: _showStickerPickerSheet,
            ),
          ],
        ),
      ),
    );
  }
}