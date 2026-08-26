import 'package:flutter/material.dart';

import '../../data/private_message.dart';
import 'chat_helpers.dart';
import '../../widgets/waveform_widget.dart';

const _kBrand = Color(0xFF102A72);

class PrivateChatInputBar extends StatelessWidget {
  final bool isUploadingAttachment;
  final PrivateMessage? replyingTo;
  final VoidCallback onCancelReply;

  final bool isRecording;
  final bool isPaused;
  final int recordingSeconds;
  final Stream<List<double>> liveWaveform;
  final VoidCallback onCancelRecording;
  final VoidCallback onTogglePauseRecording;
  final VoidCallback onStopRecordingAndSend;
  final VoidCallback onStartRecording;

  final TextEditingController controller;
  final ValueChanged<String> onMessageInputChange;
  final VoidCallback onSendMessage;

  final bool showAttachMenu;
  final ValueChanged<bool> onShowAttachMenuChange;
  final VoidCallback onPickImageVideo;
  final VoidCallback onPickAudio;
  final VoidCallback onPickFile;
  final VoidCallback onShowStickerPicker;

  const PrivateChatInputBar({
    super.key,
    required this.isUploadingAttachment,
    required this.replyingTo,
    required this.onCancelReply,
    required this.isRecording,
    required this.isPaused,
    required this.recordingSeconds,
    required this.liveWaveform,
    required this.onCancelRecording,
    required this.onTogglePauseRecording,
    required this.onStopRecordingAndSend,
    required this.onStartRecording,
    required this.controller,
    required this.onMessageInputChange,
    required this.onSendMessage,
    required this.showAttachMenu,
    required this.onShowAttachMenuChange,
    required this.onPickImageVideo,
    required this.onPickAudio,
    required this.onPickFile,
    required this.onShowStickerPicker,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingTo != null) _ReplyPreviewBar(message: replyingTo!, onCancel: onCancelReply),
            if (isUploadingAttachment)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            if (isRecording)
              _RecordingBar(
                isPaused: isPaused,
                seconds: recordingSeconds,
                liveWaveform: liveWaveform,
                onCancel: onCancelRecording,
                onTogglePause: onTogglePauseRecording,
                onStopAndSend: onStopRecordingAndSend,
              )
            else
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.add_circle_outline, color: _kBrand),
                    onPressed: () => onShowAttachMenuChange(!showAttachMenu),
                  ),
                  IconButton(
                    icon: Icon(Icons.emoji_emotions_outlined, color: _kBrand),
                    onPressed: onShowStickerPicker,
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      onChanged: onMessageInputChange,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  controller.text.trim().isEmpty
                      ? IconButton(
                    icon: Icon(Icons.mic, color: _kBrand),
                    onPressed: onStartRecording,
                  )
                      : CircleAvatar(
                    backgroundColor: const Color(0xFF1565C0),
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 18),
                      onPressed: onSendMessage,
                    ),
                  ),
                ],
              ),
            if (showAttachMenu && !isRecording)
              _AttachMenu(
                onPickImageVideo: onPickImageVideo,
                onPickAudio: onPickAudio,
                onPickFile: onPickFile,
              ),
          ],
        ),
      ),
    );
  }
}

class _ReplyPreviewBar extends StatelessWidget {
  final PrivateMessage message;
  final VoidCallback onCancel;

  const _ReplyPreviewBar({required this.message, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _kBrand.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${message.senderName.isEmpty ? "message" : message.senderName}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kBrand),
                ),
                Text(
                  previewLabelFor(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onCancel),
        ],
      ),
    );
  }
}

class _RecordingBar extends StatelessWidget {
  final bool isPaused;
  final int seconds;
  final Stream<List<double>> liveWaveform;
  final VoidCallback onCancel;
  final VoidCallback onTogglePause;
  final VoidCallback onStopAndSend;

  const _RecordingBar({
    required this.isPaused,
    required this.seconds,
    required this.liveWaveform,
    required this.onCancel,
    required this.onTogglePause,
    required this.onStopAndSend,
  });

  String _fmt(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: onCancel),
        Icon(Icons.fiber_manual_record, color: isPaused ? Colors.grey : Colors.red, size: 14),
        const SizedBox(width: 6),
        Text(_fmt(seconds)),
        const SizedBox(width: 10),
        // The actual waveform — was previously just a Spacer() here,
        // which is why nothing but empty space (or a static line if
        // your bubble widget draws one) ever showed.
        Expanded(
          child: StreamBuilder<List<double>>(
            stream: liveWaveform,
            builder: (context, snapshot) {
              final bars = snapshot.data ?? const [];
              if (bars.isEmpty) {
                // Nothing captured yet (first ~100ms) — draw a thin
                // placeholder instead of nothing so the bar doesn't
                // visually jump when the first sample lands.
                return const SizedBox.shrink();
              }
              return LiveWaveformView(bars: bars, height: 28);
            },
          ),
        ),
        IconButton(
          icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, color: _kBrand),
          onPressed: onTogglePause,
        ),
        CircleAvatar(
          backgroundColor: const Color(0xFF1565C0),
          child: IconButton(
            icon: const Icon(Icons.send, color: Colors.white, size: 18),
            onPressed: onStopAndSend,
          ),
        ),
      ],
    );
  }
}

class _AttachMenu extends StatelessWidget {
  final VoidCallback onPickImageVideo;
  final VoidCallback onPickAudio;
  final VoidCallback onPickFile;

  const _AttachMenu({
    required this.onPickImageVideo,
    required this.onPickAudio,
    required this.onPickFile,
  });

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String label, VoidCallback onTap) {
      return InkWell(
        onTap: onTap,
        child: Column(
          children: [
            CircleAvatar(backgroundColor: _kBrand, child: Icon(icon, color: Colors.white)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          item(Icons.photo_camera_outlined, 'Photo/Video', onPickImageVideo),
          item(Icons.audiotrack_outlined, 'Audio', onPickAudio),
          item(Icons.insert_drive_file_outlined, 'File', onPickFile),
        ],
      ),
    );
  }
}