import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

/// "today at 3:05 PM", "yesterday at 9:12 AM", or "12/3" — for
/// "Last seen …". Compares calendar days, not 24-hour windows.
String formatLastSeen(int millis, {DateTime? now}) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  final today = now ?? DateTime.now();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final time = '$h:${d.minute.toString().padLeft(2, '0')} '
      '${d.hour >= 12 ? 'PM' : 'AM'}';
  if (days <= 0) return 'today at $time';
  if (days == 1) return 'yesterday at $time';
  return '${d.month}/${d.day}';
}

/// Rebuilds with `presence/{uid}` live: whether [uid] is online and when
/// they were last seen (0 = never). The database shares one listener per
/// path, so many rows for the same person cost nothing extra.
class PresenceBuilder extends StatefulWidget {
  const PresenceBuilder({super.key, required this.uid, required this.builder});

  final String? uid;
  final Widget Function(BuildContext context, bool online, int lastSeen)
      builder;

  @override
  State<PresenceBuilder> createState() => _PresenceBuilderState();
}

class _PresenceBuilderState extends State<PresenceBuilder> {
  StreamSubscription<DatabaseEvent>? _sub;
  bool _online = false;
  int _lastSeen = 0;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(PresenceBuilder old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) _listen();
  }

  void _listen() {
    _sub?.cancel();
    _online = false;
    _lastSeen = 0;
    final uid = widget.uid;
    if (uid == null || uid.isEmpty) return;
    _sub = FirebaseDatabase.instance.ref('presence/$uid').onValue.listen(
      (event) {
        final val = event.snapshot.value;
        if (!mounted) return;
        setState(() {
          _online = val is Map && val['online'] == true;
          _lastSeen = val is Map ? (val['lastSeen'] as num?)?.toInt() ?? 0 : 0;
        });
      },
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _online, _lastSeen);
}

/// "Online" in green, or "Last seen …"; empty when nothing is known.
class PresenceLabel extends StatelessWidget {
  const PresenceLabel({super.key, required this.uid, this.fontSize = 12});

  final String? uid;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return PresenceBuilder(
      uid: uid,
      builder: (context, online, lastSeen) {
        if (online) {
          return Text('Online',
              style: TextStyle(
                  fontSize: fontSize,
                  color: const Color(0xFF2E7D32),
                  fontWeight: FontWeight.w600));
        }
        if (lastSeen <= 0) return const SizedBox.shrink();
        return Text('Last seen ${formatLastSeen(lastSeen)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fontSize, color: Colors.grey));
      },
    );
  }
}

/// A green dot on the corner of [child] (an avatar) while [uid] is online.
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.uid, required this.child});

  final String? uid;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PresenceBuilder(
      uid: uid,
      builder: (context, online, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: const Color(0xFF43A047),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
