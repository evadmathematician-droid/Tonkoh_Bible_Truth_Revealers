import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/ui/chat_theme.dart';

/// Every text colour of the chat palettes against the surface it sits on
/// must meet WCAG AA (4.5:1).
void main() {
  for (final (name, p) in [
    ('light', ChatPalette.light),
    ('dark', ChatPalette.dark),
  ]) {
    group('$name palette', () {
      final pairs = <String, (Color, Color)>{
        'outgoing text': (p.outgoingText, p.outgoing),
        'outgoing time/ticks': (p.outgoingMeta, p.outgoing),
        'outgoing link': (p.outgoingLink, p.outgoing),
        'read tick': (p.readTick, p.outgoing),
        'incoming text': (p.incomingText, p.incoming),
        'incoming time': (p.incomingMeta, p.incoming),
        'incoming link': (p.incomingLink, p.incoming),
        'incoming accent': (p.incomingAccent, p.incoming),
        'date chip': (p.chipText, p.chip),
        'input text': (p.inputText, p.inputBar),
        'input hint': (p.inputHint, p.inputBar),
        'missed call on incoming': (p.missedCall, p.incoming),
      };
      pairs.forEach((label, pair) {
        test(label, () {
          final ratio = contrastRatio(pair.$1, pair.$2);
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: '$label is ${ratio.toStringAsFixed(2)}:1');
        });
      });
    });
  }

  test('the spec colours are used as given', () {
    expect(ChatPalette.light.background, const Color(0xFFECEAF3));
    expect(ChatPalette.light.outgoing, const Color(0xFF1E3A5F));
    expect(ChatPalette.light.outgoingMeta, const Color(0xFFC9D6EA));
    expect(ChatPalette.light.incomingMeta, const Color(0xFF6B6B78));
    expect(ChatPalette.light.incomingLink, const Color(0xFF1565C0));
    expect(ChatPalette.light.outgoingLink, const Color(0xFF9CC8FF));
    expect(ChatPalette.light.chip, const Color(0xFFD9D5E6));
    expect(ChatPalette.light.chipText, const Color(0xFF3D3A4A));
    expect(ChatPalette.dark.background, const Color(0xFF16141D));
    expect(ChatPalette.dark.outgoing, const Color(0xFF2B4C7E));
    expect(ChatPalette.dark.incoming, const Color(0xFF25232E));
    expect(ChatPalette.dark.incomingText, const Color(0xFFECEAF3));
  });
}
