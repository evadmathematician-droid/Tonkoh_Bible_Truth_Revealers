import '../../data/private_message.dart';

/// Photos sent together, shown as one grid bubble (WhatsApp-style).
///
/// A group is a run of at least two consecutive photos from the same
/// sender, each within [window] of the one before, none with a caption
/// (a captioned photo stands alone so its text stays with it). Only the
/// first may quote a reply. Works the same on both phones, with no extra
/// data in the message.
class ImageGroups {
  ImageGroups._(this.leads, this.hidden);

  /// Index of the newest photo of each group → the group's indices, oldest
  /// first. The group is drawn at that index.
  final Map<int, List<int>> leads;

  /// Indices drawn inside a group instead of on their own.
  final Set<int> hidden;

  static const Duration window = Duration(seconds: 60);

  static bool _groupable(PrivateMessage m) =>
      m.type == 'image' && m.text.trim().isEmpty && m.fileUrl.isNotEmpty;

  /// [messages] in time order (oldest first).
  factory ImageGroups.of(List<PrivateMessage> messages) {
    final leads = <int, List<int>>{};
    final hidden = <int>{};
    var run = <int>[];

    void close() {
      if (run.length >= 2) {
        leads[run.last] = run;
        hidden.addAll(run.sublist(0, run.length - 1));
      }
      run = <int>[];
    }

    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (!_groupable(m)) {
        close();
        continue;
      }
      if (run.isNotEmpty) {
        final prev = messages[run.last];
        final continues = prev.senderId == m.senderId &&
            m.timestamp - prev.timestamp <= window.inMilliseconds &&
            m.replyToId.isEmpty;
        if (!continues) close();
      }
      run.add(i);
    }
    close();
    return ImageGroups._(leads, hidden);
  }

  /// The tick for a whole group: failed if any failed, sending while any
  /// is still on its way, otherwise the least-advanced state.
  static int statusOf(Iterable<PrivateMessage> group) {
    final statuses = group.map((m) => m.status).toList();
    if (statuses.contains(MessageStatus.failed)) return MessageStatus.failed;
    if (statuses.contains(MessageStatus.uploading)) return MessageStatus.uploading;
    return statuses.reduce((a, b) => a < b ? a : b);
  }
}
