import 'package:flutter/material.dart';

import '../../ui/chat_theme.dart';

/// Shared sizing + building blocks for the message-composer row used on
/// both the Audio screen (`AudioBottomBar`) and the Private Chat screen
/// (`PrivateChatInputBar`), so the two rows are visually and behaviourally
/// identical on every platform (Android / iOS / Web / Windows).
///
/// Proportions follow the standard messaging-app convention (WhatsApp /
/// Telegram / Signal): the text field takes the majority of the width and
/// every action is a small, evenly-sized icon button. The visible icon /
/// filled circle is ~[kInputBarButtonSize] dp, but the *tappable* area is
/// always [kInputBarTapTarget] dp (Material's minimum recommended touch
/// target) — the extra space is transparent padding around the glyph, so
/// nothing shrinks below an accessible hit area even though it looks
/// compact.
const double kInputBarTapTarget = 48;
const double kInputBarButtonSize = 40;
const double kInputBarIconSize = 22;

/// Height the text field settles at on a single line — keeps the field and
/// the icon buttons the same visual height when the row is at rest.
const double kInputBarFieldMinHeight = 42;

const Color _kBrandBlue = Color(0xFF102A72);
const Color _kSendBlue = Color(0xFF1565C0);

/// A borderless icon action (attach, emoji, mic, upload, pause, delete…).
/// 48 dp hit area, [kInputBarIconSize] glyph.
class InputBarIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;
  final String? tooltip;

  const InputBarIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    // Brand blue, or the chat palette's light accent on a dark chat bar.
    final chat = context.dependOnInheritedWidgetOfExactType<ChatTheme>();
    final fallback = chat?.palette.brightness == Brightness.dark
        ? chat!.palette.incomingAccent
        : _kBrandBlue;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: kInputBarIconSize, color: color ?? fallback),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(
        width: kInputBarTapTarget,
        height: kInputBarTapTarget,
      ),
    );
  }
}

/// The filled circular primary action (send / stop-and-send). 48 dp hit
/// area, [kInputBarButtonSize] dp coloured circle, [kInputBarIconSize]
/// glyph.
class InputBarSendButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final Color color;
  final String? tooltip;

  const InputBarSendButton({
    super.key,
    required this.onPressed,
    this.icon = Icons.send,
    this.color = _kSendBlue,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final button = InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: kInputBarTapTarget,
        height: kInputBarTapTarget,
        child: Center(
          child: Container(
            width: kInputBarButtonSize,
            height: kInputBarButtonSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: kInputBarIconSize),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Shared `InputDecoration` for the composer text field so the pill looks
/// the same in both bars. [filledGrey] switches between the outlined pill
/// (Private Chat) and the filled grey pill (Audio screen), preserving each
/// screen's existing look while unifying the metrics.
InputDecoration inputBarFieldDecoration({
  required String hintText,
  bool filledGrey = false,
}) {
  return InputDecoration(
    hintText: hintText,
    hintStyle: const TextStyle(fontSize: 15),
    isDense: true,
    filled: filledGrey,
    fillColor: filledGrey ? const Color(0xFFF1F3F5) : null,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(22),
      borderSide: filledGrey ? BorderSide.none : const BorderSide(),
    ),
    enabledBorder: filledGrey
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide.none,
          )
        : null,
  );
}

const TextStyle kInputBarFieldTextStyle = TextStyle(fontSize: 15);
