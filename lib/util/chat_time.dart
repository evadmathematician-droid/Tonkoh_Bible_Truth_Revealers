import 'package:intl/intl.dart';

/// WhatsApp-style time formatting shared by the private chat screen and
/// the audio discussion feed.

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Label for a sticky date divider between message groups:
/// "Today", "Yesterday", a weekday name for the last 7 days, otherwise
/// a numeric date ("30/08/2026").
String dateDividerLabel(int millis, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  final today = DateTime(ref.year, ref.month, ref.day);
  final that = DateTime(date.year, date.month, date.day);
  final diffDays = today.difference(that).inDays;

  if (diffDays == 0) return 'Today';
  if (diffDays == 1) return 'Yesterday';
  if (diffDays > 1 && diffDays < 7) return DateFormat('EEEE').format(date);
  return DateFormat('dd/MM/yyyy').format(date);
}

/// The small time stamp shown under a single message.
///  * < 1 min ago  -> "now"
///  * < 60 min ago -> "5 min ago"
///  * same day     -> clock time ("10:42 PM")
///  * earlier      -> clock time (the divider already carries the day)
String messageClock(int millis, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = ref.difference(date);

  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  return DateFormat('h:mm a').format(date);
}

/// Longer form for headers / "last seen" style lines: includes the day
/// when it isn't today.
String messageDateTime(int millis, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  final clock = DateFormat('h:mm a').format(date);
  if (isSameDay(ref, date)) return 'today at $clock';

  final yesterday =
      DateTime(ref.year, ref.month, ref.day).subtract(const Duration(days: 1));
  if (isSameDay(yesterday, date)) return 'yesterday at $clock';

  return '${DateFormat('dd/MM/yyyy').format(date)} at $clock';
}
