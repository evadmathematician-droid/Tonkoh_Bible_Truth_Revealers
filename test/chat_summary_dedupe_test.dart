import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/data/chat_summary.dart';

ChatSummary _s({
  required String chatId,
  required String otherUid,
  String otherName = 'Someone',
  int lastTimestamp = 0,
  int unread = 0,
}) {
  return ChatSummary(
    chatId: chatId,
    otherUid: otherUid,
    otherName: otherName,
    otherPhotoUrl: '',
    lastMessage: 'hi',
    lastTimestamp: lastTimestamp,
    unread: unread,
    lastReadTimestamp: 0,
  );
}

void main() {
  test('collapses the same number stored in different formats into one row', () {
    final rows = [
      _s(chatId: 'a_+23276123456', otherUid: '+23276123456', lastTimestamp: 100, unread: 1),
      _s(chatId: 'a_23276123456', otherUid: '23276123456', lastTimestamp: 300, unread: 2),
      _s(chatId: 'a_00023276123456', otherUid: '00023276123456', lastTimestamp: 200, unread: 3),
    ];

    final out = ChatSummary.dedupeByPerson(rows);

    expect(out, hasLength(1));
    expect(out.first.lastTimestamp, 300); // most recent row kept
    expect(out.first.unread, 6); // unread summed across merged rows
  });

  test('keeps genuinely different people apart and sorts newest first', () {
    final rows = [
      _s(chatId: 'a_+23276111111', otherUid: '+23276111111', lastTimestamp: 100),
      _s(chatId: 'a_+23276222222', otherUid: '+23276222222', lastTimestamp: 500),
    ];

    final out = ChatSummary.dedupeByPerson(rows);

    expect(out, hasLength(2));
    expect(out.first.otherUid, '+23276222222');
  });

  test('non-phone (legacy anonymous) ids are left as separate rows', () {
    final rows = [
      _s(chatId: 'x_abc', otherUid: 'aQ9xKt2Lp0', otherName: 'Legacy', lastTimestamp: 10),
      _s(chatId: 'x_def', otherUid: 'zR1yLu3Mq7', otherName: 'Legacy', lastTimestamp: 20),
    ];

    final out = ChatSummary.dedupeByPerson(rows);

    expect(out, hasLength(2));
  });
}
