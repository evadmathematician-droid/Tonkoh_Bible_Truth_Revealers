/// Small model referenced by AudioScreen's replyTarget state and passed
/// into AudioBottomBar (which you already have) and AudioFeedList.
class ReplyTarget {
  final String id;
  final String type; // "audio" or "text"
  final String preview;

  const ReplyTarget({required this.id, required this.type, required this.preview});
}