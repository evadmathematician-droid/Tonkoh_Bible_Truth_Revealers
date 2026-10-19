import 'dart:math' as math;

import 'package:flutter/material.dart';

/// "Morning Lilac" — the chat screen's own look, distinct from the teal
/// audio feed, WhatsApp beige and Telegram blue. Every chat colour lives
/// here; bubbles read it through [ChatTheme.of].
///
/// Every text/background pair is WCAG AA (≥ 4.5:1) — checked by
/// test/chat_theme_test.dart.
@immutable
class ChatPalette {
  final Brightness brightness;
  final Color background;
  final Color pattern; // doves and crosses, painted very faintly
  final Color outgoing;
  final Color outgoingText;
  final Color outgoingMeta; // time + ticks on my bubbles
  final Color outgoingLink;
  final Color incoming;
  final Color incomingText;
  final Color incomingMeta;
  final Color incomingLink;

  /// Accent on incoming bubbles (reply bar, file/audio icons).
  final Color incomingAccent;
  final Color readTick;
  final Color chip; // date chips, system notes
  final Color chipText;
  final Color inputBar;
  final Color inputText;
  final Color inputHint;
  final Color missedCall;

  const ChatPalette({
    required this.brightness,
    required this.background,
    required this.pattern,
    required this.outgoing,
    required this.outgoingText,
    required this.outgoingMeta,
    required this.outgoingLink,
    required this.incoming,
    required this.incomingText,
    required this.incomingMeta,
    required this.incomingLink,
    required this.incomingAccent,
    required this.readTick,
    required this.chip,
    required this.chipText,
    required this.inputBar,
    required this.inputText,
    required this.inputHint,
    required this.missedCall,
  });

  static const light = ChatPalette(
    brightness: Brightness.light,
    background: Color(0xFFECEAF3), // soft lilac-grey
    pattern: Color(0x0D3D3A4A), // ~5 %
    outgoing: Color(0xFF1E3A5F), // deep navy, as the app title
    outgoingText: Color(0xFFFFFFFF),
    outgoingMeta: Color(0xFFC9D6EA),
    outgoingLink: Color(0xFF9CC8FF),
    incoming: Color(0xFFFFFFFF),
    incomingText: Color(0xFF1B1B1F),
    incomingMeta: Color(0xFF6B6B78),
    incomingLink: Color(0xFF1565C0),
    incomingAccent: Color(0xFF1E3A5F),
    readTick: Color(0xFF7FD3FF), // read ticks sit on the navy bubble
    chip: Color(0xFFD9D5E6),
    chipText: Color(0xFF3D3A4A),
    inputBar: Color(0xFFFFFFFF),
    inputText: Color(0xFF1B1B1F),
    inputHint: Color(0xFF6B6B78),
    missedCall: Color(0xFFC62828),
  );

  static const dark = ChatPalette(
    brightness: Brightness.dark,
    background: Color(0xFF16141D),
    pattern: Color(0x0DECEAF3),
    outgoing: Color(0xFF2B4C7E),
    outgoingText: Color(0xFFFFFFFF),
    outgoingMeta: Color(0xFFC9D6EA),
    outgoingLink: Color(0xFFB8D8FF),
    incoming: Color(0xFF25232E),
    incomingText: Color(0xFFECEAF3),
    incomingMeta: Color(0xFFA9A6B8),
    incomingLink: Color(0xFF9CC8FF),
    incomingAccent: Color(0xFFB8C7E6),
    readTick: Color(0xFF7FD3FF),
    chip: Color(0xFF2E2B3A),
    chipText: Color(0xFFD9D5E6),
    inputBar: Color(0xFF1F1C28),
    inputText: Color(0xFFECEAF3),
    inputHint: Color(0xFFA9A6B8),
    missedCall: Color(0xFFFF8A80),
  );

  /// The palette for the phone's light/dark setting.
  static ChatPalette forBrightness(Brightness b) =>
      b == Brightness.dark ? dark : light;

  Color bubble(bool mine) => mine ? outgoing : incoming;
  Color text(bool mine) => mine ? outgoingText : incomingText;
  Color meta(bool mine) => mine ? outgoingMeta : incomingMeta;
  Color link(bool mine) => mine ? outgoingLink : incomingLink;

  /// Icons, reply bars and names inside a bubble.
  Color accent(bool mine) => mine ? outgoingText : incomingAccent;

  /// Secondary text inside a bubble (file size, quoted text).
  Color secondary(bool mine) => mine ? outgoingMeta : incomingMeta;
}

/// Makes the [ChatPalette] available to every widget inside a chat.
class ChatTheme extends InheritedWidget {
  final ChatPalette palette;
  const ChatTheme({super.key, required this.palette, required super.child});

  /// The chat palette, or the light one outside a chat screen.
  static ChatPalette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatTheme>()?.palette ??
      ChatPalette.light;

  @override
  bool updateShouldNotify(ChatTheme oldWidget) => palette != oldWidget.palette;
}

/// WCAG relative luminance contrast ratio between two opaque colours.
double contrastRatio(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double lum(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = lum(a), lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The faint tiled background: small doves and crosses at ~5 % opacity.
/// Static and isolated in its own layer, so it costs nothing while the
/// message list scrolls.
class ChatBackground extends StatelessWidget {
  final ChatPalette palette;
  final Widget child;
  const ChatBackground({super.key, required this.palette, required this.child});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: palette.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _DoveCrossPainter(palette.pattern),
              isComplex: true,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _DoveCrossPainter extends CustomPainter {
  final Color color;
  _DoveCrossPainter(this.color);

  static const double _tile = 96;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final dove = _dovePath();
    for (double y = 0, row = 0; y < size.height + _tile; y += _tile, row++) {
      final shift = row.toInt().isOdd ? _tile / 2 : 0.0;
      for (double x = -_tile / 2; x < size.width + _tile; x += _tile) {
        _cross(canvas, paint, Offset(x + shift + 20, y + 22));
        canvas.save();
        canvas.translate(x + shift + 58, y + 62);
        canvas.drawPath(dove, paint);
        canvas.restore();
      }
    }
  }

  void _cross(Canvas canvas, Paint paint, Offset c) {
    final r = Radius.circular(1.2);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: c.translate(0, 1.5), width: 3.2, height: 15), r),
        paint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: c.translate(0, -2), width: 10, height: 3.2), r),
        paint);
  }

  /// A small flying dove (~22 × 14), origin at its body centre.
  Path _dovePath() {
    return Path()
      // body and tail
      ..moveTo(-11, 1)
      ..quadraticBezierTo(-4, -2, 4, 0)
      ..quadraticBezierTo(8, -1, 10, -4) // head
      ..quadraticBezierTo(11, -1, 8, 1.5)
      ..quadraticBezierTo(3, 5, -6, 4)
      ..lineTo(-11, 6)
      ..lineTo(-9, 2.5)
      ..close()
      // raised wing
      ..moveTo(-3, 0)
      ..quadraticBezierTo(-1, -9, 5, -10)
      ..quadraticBezierTo(2, -4, 2, 0)
      ..close();
  }

  @override
  bool shouldRepaint(_DoveCrossPainter old) => old.color != color;
}
