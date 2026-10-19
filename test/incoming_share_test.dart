import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/share/incoming_share.dart';

void main() {
  group('links (TikTok / YouTube share text)', () {
    test('TikTok: link inside promo text', () {
      final s = IncomingShare.fromMap({
        'text': 'Check out this video! https://vm.tiktok.com/ZMabc123/ #fyp',
      });
      expect(s.link, 'https://vm.tiktok.com/ZMabc123/');
      expect(s.files, isEmpty);
    });

    test('YouTube: title in subject, bare link in text', () {
      final s = IncomingShare.fromMap({
        'text': 'https://youtu.be/dQw4w9WgXcQ',
        'subject': 'Sunday Sermon — Faith',
      });
      expect(s.link, 'https://youtu.be/dQw4w9WgXcQ');
      expect(s.message, 'Sunday Sermon — Faith\nhttps://youtu.be/dQw4w9WgXcQ');
    });

    test('subject already in text is not repeated', () {
      final s = IncomingShare.fromMap({
        'text': 'Great word https://example.org/a',
        'subject': 'Great word',
      });
      expect(s.message, 'Great word https://example.org/a');
    });

    test('trailing punctuation is not part of the link', () {
      expect(firstLink('see (https://example.org/x).'), 'https://example.org/x');
      expect(firstLink('no link here'), isNull);
    });
  });

  group('files (WhatsApp / gallery)', () {
    test('media files are classified, others flagged', () {
      final s = IncomingShare.fromMap({
        'files': [
          {'path': '/c/a.jpg', 'mimeType': 'image/jpeg', 'name': 'a.jpg'},
          {'path': '/c/b.mp4', 'mimeType': 'video/mp4', 'name': 'b.mp4'},
          {'path': '/c/c.opus', 'mimeType': 'audio/ogg', 'name': 'PTT.opus'},
          {'path': '/c/d.pdf', 'mimeType': 'application/pdf', 'name': 'd.pdf'},
        ],
      });
      expect(s.files.map((f) => f.kind), ['image', 'video', 'audio', 'file']);
      expect(s.files.where((f) => f.isMedia), hasLength(3));
      expect(s.link, isNull);
    });

    test('bad rows are dropped and empty shares detected', () {
      final s = IncomingShare.fromMap({
        'text': '  ',
        'files': [
          {'path': '', 'mimeType': 'image/png'},
          'garbage',
        ],
      });
      expect(s.files, isEmpty);
      expect(s.isEmpty, isTrue);
    });
  });

  test('Direct Share shortcut preselects the Audio Screen', () {
    expect(IncomingShare.fromMap({'text': 'x', 'target': 'audio'}).toAudioScreen,
        isTrue);
    expect(IncomingShare.fromMap({'text': 'x'}).toAudioScreen, isFalse);
  });
}
