import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/data/private_message.dart';
import 'package:tbtrapp/screens/chat/message_bubbles.dart';
import 'package:tbtrapp/ui/chat_theme.dart';
import 'package:tbtrapp/ui/linkified_text.dart';

/// Renders the "Morning Lilac" palette as a phone-sized PNG (light and
/// dark) for docs/PHONE_CHAT_FIX.md. Not a regression test, so it only
/// runs on request:
///   RENDER_PREVIEWS=1 flutter test --update-goldens test/chat_theme_preview_test.dart
void main() {
  final skip = !Platform.environment.containsKey('RENDER_PREVIEWS');

  setUpAll(() async {
    if (skip) return;
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? 'E:/APACHE/flutter'}'
        '/bin/cache/artifacts/material_fonts';
    Future<ByteData> load(String f) async =>
        ByteData.sublistView(await File('$fonts/$f').readAsBytes());
    final roboto = FontLoader('Roboto')
      ..addFont(load('roboto-regular.ttf'))
      ..addFont(load('roboto-medium.ttf'))
      ..addFont(load('roboto-bold.ttf'));
    await roboto.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(load('materialicons-regular.otf'));
    await icons.load();
  });

  for (final dark in [false, true]) {
    testWidgets('chat preview ${dark ? 'dark' : 'light'}', skip: skip,
        (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final palette = dark ? ChatPalette.dark : ChatPalette.light;
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
        home: ChatTheme(palette: palette, child: _Preview(palette)),
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byType(_Preview),
          matchesGoldenFile('../docs/chat_colors_${dark ? 'dark' : 'light'}.png'));
    });
  }
}

class _Preview extends StatelessWidget {
  final ChatPalette p;
  const _Preview(this.p);

  Widget _bubble(bool mine, Widget content, String time,
      {int status = MessageStatus.delivered, bool read = false}) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 290),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
        decoration: BoxDecoration(
          color: p.bubble(mine),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            content,
            const SizedBox(height: 3),
            Align(
              alignment: Alignment.bottomRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(time, style: TextStyle(fontSize: 10.5, color: p.meta(mine))),
                if (mine) ...[
                  const SizedBox(width: 4),
                  MessageStatusTick(
                      status: status,
                      isRead: read,
                      color: p.outgoingMeta,
                      readColor: p.readTick),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _text(bool mine, String t) => LinkifiedText(t,
      style: TextStyle(color: p.text(mine), fontSize: 15, height: 1.3),
      linkColor: p.link(mine));

  @override
  Widget build(BuildContext context) {
    final reply = PrivateMessage(
      id: 'r',
      timestamp: 0,
      senderId: 'x',
      replyToId: 'q',
      replyToText: 'Can you share the Sunday sermon?',
      replyToSenderName: 'Pastor John',
    );
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: const Color(0xFF102A72),
        foregroundColor: Colors.white,
        title: const Text('Pastor John', style: TextStyle(fontSize: 16)),
      ),
      body: ChatBackground(
        palette: p,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                      color: p.chip, borderRadius: BorderRadius.circular(10)),
                  child: Text('Today',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: p.chipText,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              _bubble(false, _text(false, 'Good morning! Can you share the Sunday sermon?'), '9:12 AM'),
              _bubble(
                  true,
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ReplyQuotePreview(message: reply, isMine: true, senderLabel: 'Pastor John'),
                    _text(true, 'Yes — here it is: https://tbtr.app/sermons/sunday'),
                  ]),
                  '9:14 AM',
                  read: true),
              _bubble(false, _text(false, 'Thank you. See www.biblegateway.com for John 3:16'), '9:15 AM'),
              _bubble(
                  true,
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.play_arrow, color: p.text(true)),
                    const SizedBox(width: 6),
                    for (var i = 0; i < 22; i++)
                      Container(
                        width: 3,
                        height: 6.0 + (i * 7 % 18),
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        color: p.text(true).withValues(alpha: i < 9 ? 1 : 0.35),
                      ),
                    const SizedBox(width: 6),
                    Text('0:24', style: TextStyle(color: p.text(true), fontSize: 12)),
                  ]),
                  '9:16 AM'),
              _bubble(true, _text(true, 'Sent while offline…'), '9:17 AM',
                  status: MessageStatus.pending),
            ]),
          ),
          Container(
            color: p.inputBar,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(children: [
              Icon(Icons.add_circle_outline,
                  color: p.brightness == Brightness.dark
                      ? p.incomingAccent
                      : const Color(0xFF102A72)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.inputHint),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Text('Message',
                      style: TextStyle(color: p.inputHint, fontSize: 15)),
                ),
              ),
              const SizedBox(width: 8),
              const CircleAvatar(
                radius: 20,
                backgroundColor: Color(0xFF1565C0),
                child: Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
