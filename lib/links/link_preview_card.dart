import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../screens/audio/global_audio_player.dart';
import 'link_preview.dart';
import 'link_preview_service.dart';

/// Tallest a card's thumbnail gets (vertical TikTok covers are cropped to
/// this rather than filling the screen).
const double kLinkThumbMaxHeight = 260;

/// WhatsApp-style preview card for a shared link: full-width thumbnail with
/// a round ▶ for videos and a duration badge, site icon + name, bold title,
/// description (3 lines, "more" to expand), author and the short link.
///
/// The thumbnail's height is fixed from the stored size *before* the image
/// loads, so lists never jump. The whole card opens the link
/// ([openLinkPreview]) unless [onTap] is given.
class LinkPreviewCard extends StatefulWidget {
  final LinkPreview preview;
  final VoidCallback? onTap;

  /// Text colours; the card's own background is translucent so it fits on
  /// white feed cards and on coloured chat bubbles alike.
  final Color? foreground;
  final Color? secondary;
  final Color? linkColor;

  /// Shows a close button (composer preview the user can remove).
  final VoidCallback? onRemove;

  /// Small strip (thumbnail left) for the composer.
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
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.foreground ?? const Color(0xFF1B1B1F);
    final sub = widget.secondary ?? const Color(0xFF5F6170);
    final link = widget.linkColor ?? const Color(0xFF1565C0);
    final p = widget.preview;
    final compact = widget.compact;
    final site = p.siteName.isEmpty ? siteNameFor(p.url) : p.siteName;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          linkSiteIcon(p, 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(site,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600, color: sub)),
          ),
        ]),
        if (p.title.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(p.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: compact ? 13.5 : 14.5,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  color: fg)),
        ],
        if (p.description.isNotEmpty && !compact) ...[
          const SizedBox(height: 3),
          _Description(
            text: p.description,
            expanded: _expanded,
            color: sub,
            moreColor: link,
            onMore: () => setState(() => _expanded = !_expanded),
          ),
        ],
        if (p.author.isNotEmpty && !compact) ...[
          const SizedBox(height: 3),
          Text(p.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: sub)),
        ],
        const SizedBox(height: 4),
        Text(shortLinkLabel(p.url),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: link)),
      ],
    );

    final Widget content;
    if (compact) {
      content = Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 64,
                height: 64,
                child: p.hasThumbnail
                    ? CachedNetworkImage(
                        imageUrl: p.thumbnailUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 192,
                        errorWidget: (_, __, ___) =>
                            Center(child: linkSiteIcon(p, 28)),
                      )
                    : ColoredBox(
                        color: const Color(0x14000000),
                        child: Center(child: linkSiteIcon(p, 28))),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: details),
            if (widget.onRemove != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove preview',
                icon: Icon(Icons.close, size: 18, color: sub),
                onPressed: widget.onRemove,
              ),
          ],
        ),
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.hasThumbnail) _Thumbnail(preview: p),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: details,
          ),
        ],
      );
    }

    return Semantics(
      button: true,
      label: 'Link: ${p.title.isEmpty ? p.url : p.title}',
      child: Material(
        color: fg.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap ?? () => openLinkPreview(context, p),
          child: content,
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final LinkPreview preview;
  const _Thumbnail({required this.preview});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth.isFinite ? c.maxWidth : 300.0;
      final height =
          (width / preview.aspectRatio).clamp(80.0, kLinkThumbMaxHeight);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: preview.thumbnailUrl,
              fit: BoxFit.cover,
              // Decode at the size shown — matters on low-memory phones.
              memCacheWidth: (width * dpr).ceil(),
              fadeInDuration: const Duration(milliseconds: 120),
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0x1F000000)),
              errorWidget: (_, __, ___) => ColoredBox(
                color: const Color(0x1F000000),
                child: Center(child: linkSiteIcon(preview, 40)),
              ),
            ),
            if (preview.isVideo)
              Center(
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                    color: Color(0xB3000000),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 40),
                ),
              ),
            if (preview.durationSeconds > 0)
              Positioned(
                right: 8,
                bottom: 8,
                child: _Badge(formatDuration(preview.durationSeconds)),
              ),
          ],
        ),
      );
    });
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      );
}

class _Description extends StatelessWidget {
  final String text;
  final bool expanded;
  final Color color;
  final Color moreColor;
  final VoidCallback onMore;

  const _Description({
    required this.text,
    required this.expanded,
    required this.color,
    required this.moreColor,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12.5, height: 1.3, color: color);
    return LayoutBuilder(builder: (context, c) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        maxLines: 3,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: c.maxWidth);
      final overflows = painter.didExceedMaxLines;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              maxLines: expanded ? null : 3,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: style),
          if (overflows || expanded)
            GestureDetector(
              onTap: onMore,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(expanded ? 'less' : 'more',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: moreColor)),
              ),
            ),
        ],
      );
    });
  }
}

/// "3:07" / "1:02:15".
String formatDuration(int seconds) {
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// "youtube.com/watch?v=dQw4…" — host plus a short path, like WhatsApp.
String shortLinkLabel(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
  var rest = url.substring(url.indexOf(uri.host) + uri.host.length);
  if (rest == '/' || rest.isEmpty) return host;
  if (rest.length > 28) rest = '${rest.substring(0, 27)}…';
  return '$host$rest';
}

/// The site's mark: YouTube red ▶, TikTok note, the page's favicon, or a
/// globe.
Widget linkSiteIcon(LinkPreview p, double size) {
  switch (p.kind) {
    case LinkKind.youtube:
      return Icon(Icons.smart_display,
          size: size, color: const Color(0xFFFF0000));
    case LinkKind.tiktok:
      return Icon(Icons.music_note, size: size, color: const Color(0xFF111111));
    case LinkKind.other:
      final fallback = Icon(
          siteNameFor(p.url) == 'Facebook' ? Icons.facebook : Icons.public,
          size: size,
          color: const Color(0xFF1565C0));
      if (p.iconUrl.isEmpty) return fallback;
      return SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: p.iconUrl,
          memCacheWidth: (size * 3).ceil(),
          errorWidget: (_, __, ___) => fallback,
          placeholder: (_, __) => fallback,
        ),
      );
  }
}

/// Card for an older message / post that holds a link but no saved
/// preview: fetched once on this phone (not re-hosted, nothing written to
/// anyone's data), cached by URL, then shown like any card.
class AutoLinkPreview extends StatefulWidget {
  final String text;
  final Color? foreground;
  final Color? secondary;
  final Color? linkColor;

  const AutoLinkPreview({
    super.key,
    required this.text,
    this.foreground,
    this.secondary,
    this.linkColor,
  });

  @override
  State<AutoLinkPreview> createState() => _AutoLinkPreviewState();
}

class _AutoLinkPreviewState extends State<AutoLinkPreview> {
  LinkPreview? _preview;
  String? _url;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AutoLinkPreview old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _resolve();
  }

  void _resolve() {
    final url = extractFirstUrl(widget.text);
    _url = url;
    if (url == null) {
      _preview = null;
      return;
    }
    final service = LinkPreviewService.instance;
    _preview = service.cached(url);
    if (_preview != null) return;
    service.fetch(url, rehost: false).then((p) {
      if (!mounted || _url != url) return;
      // Only worth a card if the site told us something.
      if (p.title.isEmpty && !p.hasThumbnail) return;
      setState(() => _preview = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    if (p == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: LinkPreviewCard(
        preview: p,
        foreground: widget.foreground,
        secondary: widget.secondary,
        linkColor: widget.linkColor,
      ),
    );
  }
}

/// YouTube → plays inside the app (the app's own audio pauses); TikTok and
/// everything else → their own app if installed (Android app links),
/// otherwise the browser.
Future<void> openLinkPreview(BuildContext context, LinkPreview p) async {
  final id = p.videoId.isNotEmpty ? p.videoId : youtubeVideoId(p.url);
  if (id != null) {
    final player = GlobalAudioPlayer.instance;
    if (player.isPlaying) await player.pause();
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          YouTubePlayerScreen(videoId: id, url: p.url, title: p.title),
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
