import 'package:flutter/material.dart';

import '../services/resumable_downloader.dart';

/// Circular download control that sits separately from the play button.
///
///  * Not started  -> download arrow.
///  * Downloading   -> circular progress ring with a pause glyph.
///  * Paused/failed -> ring at last progress with a resume glyph.
///  * Complete      -> small check (or hidden when [hideWhenComplete]).
///
/// Gestures:
///  * single tap  -> start / pause / resume the download.
///  * double tap  -> stop the download AND playback ([onStopPlayback]).
class MediaDownloadButton extends StatelessWidget {
  final String cacheKey;
  final String url;
  final String ext; // ".mp4", ".mp3", …
  final double size;
  final Color color;
  final Color background;

  /// Invoked on double-tap so the caller can also stop playback.
  final VoidCallback? onStopPlayback;
  final bool hideWhenComplete;

  const MediaDownloadButton({
    super.key,
    required this.cacheKey,
    required this.url,
    required this.ext,
    this.size = 40,
    this.color = Colors.white,
    this.background = Colors.black54,
    this.onStopPlayback,
    this.hideWhenComplete = true,
  });

  ResumableDownloader get _dl => ResumableDownloader.instance;

  void _single(MediaDownload state) {
    switch (state.status) {
      case DownloadStatus.downloading:
        _dl.pause(cacheKey);
        break;
      case DownloadStatus.paused:
      case DownloadStatus.failed:
        _dl.resume(cacheKey);
        break;
      case DownloadStatus.idle:
        _dl.start(cacheKey, url, ext: ext);
        break;
      case DownloadStatus.completed:
        break;
    }
  }

  void _double() {
    _dl.pause(cacheKey);
    onStopPlayback?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaDownload>(
      valueListenable: _dl.watch(cacheKey),
      builder: (context, state, _) {
        if (state.status == DownloadStatus.completed && hideWhenComplete) {
          return const SizedBox.shrink();
        }

        IconData glyph;
        switch (state.status) {
          case DownloadStatus.downloading:
            glyph = Icons.pause;
            break;
          case DownloadStatus.paused:
          case DownloadStatus.failed:
            glyph = Icons.file_download_outlined;
            break;
          case DownloadStatus.completed:
            glyph = Icons.check;
            break;
          case DownloadStatus.idle:
            glyph = Icons.file_download_outlined;
            break;
        }

        final showRing = state.status == DownloadStatus.downloading ||
            state.status == DownloadStatus.paused;

        return GestureDetector(
          onTap: () => _single(state),
          onDoubleTap: _double,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: background, shape: BoxShape.circle),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (showRing)
                  SizedBox(
                    width: size,
                    height: size,
                    child: CircularProgressIndicator(
                      value: state.total > 0 ? state.progress : null,
                      strokeWidth: 2.5,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.25),
                    ),
                  ),
                if (showRing && state.total > 0)
                  Text(
                    '${(state.progress * 100).round()}',
                    style: TextStyle(color: color, fontSize: size * 0.24),
                  )
                else
                  Icon(glyph, color: color, size: size * 0.5),
              ],
            ),
          ),
        );
      },
    );
  }
}
