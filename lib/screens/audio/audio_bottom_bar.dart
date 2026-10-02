import 'package:flutter/material.dart';

import '../components/message_input_bar.dart';

/// Composer row for the Audio screen: upload button + text field + send.
/// Sizing/behaviour comes entirely from the shared building blocks in
/// message_input_bar.dart so this row is identical to the Private Chat
/// screen's row on every platform.
class AudioBottomBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onUploadClick;
  final String? replyTargetText;
  final VoidCallback onCancelReply;

  const AudioBottomBar({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onUploadClick,
    this.replyTargetText,
    required this.onCancelReply,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyTargetText != null)
              Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.reply, size: 16, color: Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        replyTargetText!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: onCancelReply,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                InputBarIconButton(
                  icon: Icons.upload_file,
                  tooltip: 'Upload',
                  onPressed: onUploadClick,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: kInputBarFieldMinHeight),
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      style: kInputBarFieldTextStyle,
                      decoration: inputBarFieldDecoration(
                        hintText: 'Type a message…',
                        filledGrey: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                InputBarSendButton(
                  tooltip: 'Send',
                  onPressed: onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
