import 'sermon_audio.dart';
import 'text_message.dart';

/// Equivalent of the FeedItem your Compose buildFeedItems() produces.
/// I don't have buildFeedItems.kt's exact source, so this is inferred
/// from usage (feedItems.timestamp, feedItems.id, feedItems.type,
/// feedItems.sermon) in AudioScreen.kt — flagging as inferred, not a
/// faithful port. Low risk: it's just a merge+sort.
class FeedItem {
  final String id;
  final String type; // "audio" or "text"
  final int timestamp;
  final SermonAudio? sermon;
  final TextMessage? textMessage;

  FeedItem.fromSermon(SermonAudio s)
      : id = s.id,
        type = 'audio',
        timestamp = s.timestamp,
        sermon = s,
        textMessage = null;

  FeedItem.fromTextMessage(TextMessage t)
      : id = t.id,
        type = 'text',
        timestamp = t.timestamp,
        sermon = null,
        textMessage = t;
}

List<FeedItem> buildFeedItems(
    List<SermonAudio> sermons,
    List<TextMessage> textMessages,
    ) {
  final items = <FeedItem>[
    ...sermons.map(FeedItem.fromSermon),
    ...textMessages.map(FeedItem.fromTextMessage),
  ];
  items.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return items;
}