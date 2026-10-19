import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import 'link_preview.dart';

/// WhatsApp-style preview card for a shared link: large thumbnail with a
/// play button for videos, site name, title, description, author and link.
///
/// The thumbnail area keeps the image's aspect ratio *before* it loads, so a
/// list never jumps when images arrive. Tapping opens the link
/// ([openLinkPreview]) unless [onTap] is given.
class LinkPreviewCard extends StatelessWidget {
  final LinkPreview preview;
  final VoidCallback? onTap;

  /// Text colour; the card's own background is translucent so it fits on
  /// white feed cards and on coloured chat bubbles alike.
  final Color? foreground;
  final Color? secondary;
  final Color? linkColor;

  /// Shows a close button (composer preview the user can remove).
  final VoidCallback? onRemove;
  final bool compact;

  const LinkPreviewCard({
    super.key,
    required this.preview,
    this.onTap,
    this.foreground,
    this.secondary,
    this.linkColor,
    this.onRemove,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? const Color(0xFF1B1B1F);
    final sub = secondary ?? const Color(0xFF5F6170);
    final link = linkColor ?? const Color(0xFF1565C0);
    final p = preview;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p.hasThumbnail && !compact) _thumbnail(),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.hasThumbnail && compact) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: CachedNetworkImage(
                        imageUrl: p.thumbnailUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _siteIcon(p, 28)),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      _siteIcon(p, 14),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          p.siteName.isEmpty ? siteNameFor(p.url) : p.siteName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: sub),
                        ),
                      ),
                    ]),
                    if (p.title.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(p.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              color: fg)),
                    ],
                    if (p.description.isNotEmpty && !compact) ...[
                      const SizedBox(height: 3),
                      Text(p.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, height: 1.3, color: sub)),
                    ],
                    if (p.author.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(p.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: sub)),
                    ],
                    const SizedBox(height: 4),
                    Text(p.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: link)),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove preview',
                  icon: Icon(Icons.close, size: 18, color: sub),
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      label: 'Link: ${p.title.isEmpty ? p.url : p.title}',
      child: Material(
        color: fg.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap ?? () => openLinkPreview(context, p),
          child: content,
        ),
      ),
    );
  }

  Widget _thumbnail() {
    return AspectRatio(
      aspectRatio: preview.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: preview.thumbnailUrl,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 120),
            placeholder: (_, __) => const ColoredBox(color: Color(0x1F000000)),
            errorWidget: (_, __, ___) => ColoredBox(
              color: const Color(0x1F000000),
              child: Center(child: _siteIcon(preview, 40)),
            ),
          ),
          if (preview.isVideo)
            Center(
              child: Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Color(0xB3000000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 42),
              ),
            ),
        ],
      ),
    );
  }

  static Widget _siteIcon(LinkPreview p, double size) {
    return switch (p.kind) {
      LinkKind.youtube =>
        Icon(Icons.smart_display, size: size, color: const Color(0xFFFF0000)),
      LinkKind.tiktok =>
        Icon(Icons.music_note, size: size, color: const Color(0xFF111111)),
      LinkKind.other => Icon(
          switch (siteNameFor(p.url)) {
            'Facebook' => Icons.facebook,
            _ => Icons.public,
          },
          size: size,
          color: const Color(0xFF1565C0)),
    };
  }
}

/// YouTube → plays inside the app; TikTok and everything else → their own
/// app if installed (Android app links), otherwise the browser.
Future<void> openLinkPreview(BuildContext context, LinkPreview p) async {
  final id = p.videoId.isNotEmpty ? p.videoId : youtubeVideoId(p.url);
  if (id != null) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => YouTubePlayerScreen(videoId: id, url: p.url, title: p.title),
    ));
    return;
  }
  await openExternally(p.url);
}

Future<void> openExternally(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (!await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// The official YouTube embed player, with "Open in YouTube".
class YouTubePlayerScreen extends StatefulWidget {
  final String videoId;
  final String url;
  final String title;
  const YouTubePlayerScreen(
      {super.key, required this.videoId, required this.url, this.title = ''});

  @override
  State<YouTubePlayerScreen> createState() => _YouTubePlayerScreenState();
}

class _YouTubePlayerScreenState extends State<YouTubePlayerScreen> {
  late final YoutubePlayerController _controller =
      YoutubePlayerController.fromVideoId(
    videoId: widget.videoId,
    autoPlay: true,
    params: const YoutubePlayerParams(
      showFullscreenButton: true,
      strictRelatedVideos: true,
    ),
  );

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title.isEmpty ? 'YouTube' : widget.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            YoutubePlayer(controller: _controller),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54)),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open in YouTube'),
                onPressed: () {
                  _controller.pauseVideo();
                  openExternally(widget.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
