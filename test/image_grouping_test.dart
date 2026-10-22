import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/data/private_message.dart';
import 'package:tbtrapp/screens/chat/image_grouping.dart';

PrivateMessage img(String id, int ts,
        {String sender = 'me', String caption = '', String reply = '', int status = 1}) =>
    PrivateMessage(
      id: id,
      type: 'image',
      fileUrl: 'https://res.cloudinary.com/x/image/upload/$id.jpg',
      text: caption,
      timestamp: ts,
      senderId: sender,
      replyToId: reply,
      status: status,
    );

PrivateMessage text(String id, int ts) =>
    PrivateMessage(id: id, text: 'hi', timestamp: ts, senderId: 'me');

void main() {
  test('photos sent together form one group, drawn at the newest', () {
    final g = ImageGroups.of([
      text('t', 0),
      img('a', 1000),
      img('b', 1001),
      img('c', 1002),
    ]);
    expect(g.leads, {3: [1, 2, 3]});
    expect(g.hidden, {1, 2});
  });

  test('a single photo is not a group', () {
    final g = ImageGroups.of([img('a', 0), text('t', 1)]);
    expect(g.leads, isEmpty);
    expect(g.hidden, isEmpty);
  });

  test('captioned photos, other senders and gaps over a minute split groups', () {
    final g = ImageGroups.of([
      img('a', 0),
      img('b', 1),
      img('cap', 2, caption: 'look'),
      img('c', 3),
      img('d', 4, sender: 'them'),
      img('e', 5, sender: 'them'),
      img('f', 5 + 61000, sender: 'them'),
    ]);
    expect(g.leads, {1: [0, 1], 5: [4, 5]});
  });

  test('only the first photo of a group may quote a reply', () {
    final g = ImageGroups.of([
      img('a', 0, reply: 'x'),
      img('b', 1),
      img('c', 2, reply: 'y'),
    ]);
    expect(g.leads, {1: [0, 1]});
  });

  test('group tick: failed beats uploading beats the least-advanced', () {
    expect(
        ImageGroups.statusOf([
          img('a', 0, status: MessageStatus.delivered),
          img('b', 1, status: MessageStatus.uploading),
          img('c', 2, status: MessageStatus.failed),
        ]),
        MessageStatus.failed);
    expect(
        ImageGroups.statusOf([
          img('a', 0, status: MessageStatus.delivered),
          img('b', 1, status: MessageStatus.uploading),
        ]),
        MessageStatus.uploading);
    expect(
        ImageGroups.statusOf([
          img('a', 0, status: MessageStatus.delivered),
          img('b', 1, status: MessageStatus.sent),
        ]),
        MessageStatus.sent);
  });
}
