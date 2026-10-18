import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tbtrapp/data/display_names.dart';
import 'package:tbtrapp/data/feed_item.dart';
import 'package:tbtrapp/data/text_message.dart';
import 'package:tbtrapp/screens/audio/audio_feed_list.dart';
import 'package:tbtrapp/screens/audio/reply_target.dart';

const _me = '+23276000001';
const _saved = '+23276000002';
const _unsaved = '+23276000003';

FeedItem _post(String id, String senderId, String profileName) =>
    FeedItem.fromTextMessage(TextMessage(
      id: id,
      text: 'text of $id',
      timestamp: 1700000000000,
      senderId: senderId,
      senderName: profileName,
      senderPhone: senderId,
    ));

Future<List<(String, ReplyTarget)>> _pump(WidgetTester tester) async {
  DisplayNames.instance.debugSetSaved({_saved: 'Deacon Sam'});
  final taps = <(String, ReplyTarget)>[];
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: DisplayNames.instance,
      child: MaterialApp(
        home: Scaffold(
          body: AudioFeedList(
            feedItems: [
              _post('a', _me, 'My Profile Name'),
              _post('b', _saved, 'Samuel K'),
              _post('c', _unsaved, 'Stranger Chosen Name'),
            ],
            scrollController: ScrollController(),
            reactionsMap: const {},
            longPressMenuFor: null,
            onLongPress: (_) {},
            onDismissLongPressMenu: () {},
            onReact: (_, __) {},
            onReply: (_) {},
            onDelete: (_, __) {},
            onAudioPlayPauseClick: (_) {},
            onShareAudio: (_) {},
            onShareVideo: (_) {},
            onSeekChange: (_, __) {},
            onSeekFinished: (_) {},
            onImageClick: (_) {},
            onVideoTap: (_) {},
            unreadCount: 0,
            onJumpToBottom: () {},
            viewingImageUrl: null,
            onDismissImage: () {},
            currentUid: _me,
            onSenderTap: (id, target) => taps.add((id, target)),
          ),
        ),
      ),
    ),
  );
  return taps;
}

void main() {
  testWidgets('feed names follow the contact rule', (tester) async {
    await _pump(tester);

    expect(find.text('You'), findsOneWidget);
    expect(find.text('Deacon Sam'), findsOneWidget);
    // Unsaved: the number only — never their self-chosen profile name.
    expect(find.text(formatPhoneForDisplay(_unsaved)), findsOneWidget);
    expect(find.text('Stranger Chosen Name'), findsNothing);
    expect(find.text('Samuel K'), findsNothing);
  });

  testWidgets('tapping a member opens their sheet, own posts do nothing',
      (tester) async {
    final taps = await _pump(tester);

    await tester.tap(find.text('Deacon Sam'));
    await tester.tap(find.text('You'));
    await tester.pump();

    expect(taps, hasLength(1));
    expect(taps.single.$1, _saved);
    expect(taps.single.$2.id, 'b');
    expect(taps.single.$2.preview, 'text of b');
  });
}
