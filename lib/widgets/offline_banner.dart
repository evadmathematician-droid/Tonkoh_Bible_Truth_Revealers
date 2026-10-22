import 'package:flutter/material.dart';

import '../util/connection_status.dart';

/// A thin strip across the top of every screen, shown only while the phone
/// has no internet ([ConnectionStatus]). It never blocks anything: saved
/// chats, contacts and the feed stay readable, and messages typed offline
/// go out when the connection returns.
///
/// Installed in `MaterialApp.builder`. The strip takes the status-bar area,
/// and the app below it lays out as if the status bar were already
/// handled, so app bars sit right under the strip. The widget tree has the
/// same shape online and offline, so showing the strip never rebuilds the
/// app's navigator (no lost screens or scroll positions).
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectionStatus.instance.offline,
      child: child,
      builder: (context, offline, child) {
        final topInset = MediaQuery.paddingOf(context).top;
        return Column(
          children: [
            if (offline)
              Material(
                color: const Color(0xFFFFF3CD),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, topInset + 3, 12, 3),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.wifi_off, size: 14, color: Color(0xFF664D03)),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'No internet. Showing saved messages.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 12, color: Color(0xFF664D03)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              key: const ValueKey('app'),
              child: MediaQuery.removePadding(
                context: context,
                removeTop: offline,
                child: child!,
              ),
            ),
          ],
        );
      },
    );
  }
}
