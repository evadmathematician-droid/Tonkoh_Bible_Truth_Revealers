import 'dart:async';

import 'package:flutter/material.dart';

import 'link_preview.dart';
import 'link_preview_card.dart';
import 'link_preview_service.dart';

/// Shows a preview card above a message composer as soon as the text
/// contains a link (like WhatsApp), and reports it through [onChanged] so
/// the message is sent with the card. The × removes the card for this link.
class TypedLinkPreview extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<LinkPreview?> onChanged;
  final LinkPreviewService? service;

  const TypedLinkPreview({
    super.key,
    required this.controller,
    required this.onChanged,
    this.service,
  });

  @override
  State<TypedLinkPreview> createState() => _TypedLinkPreviewState();
}

class _TypedLinkPreviewState extends State<TypedLinkPreview> {
  Timer? _debounce;
  String? _url; // link currently in the text
  String? _dismissedUrl;
  LinkPreview? _preview;
  bool _loading = false;

  LinkPreviewService get _service =>
      widget.service ?? LinkPreviewService.instance;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(TypedLinkPreview old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    final url = extractFirstUrl(widget.controller.text);
    if (url == _url) return;
    _url = url;
    _debounce?.cancel();
    if (url == null) {
      _set(null, loading: false);
      _dismissedUrl = null; // text cleared/sent: next link previews again
      return;
    }
    if (url == _dismissedUrl) return;
    _debounce = Timer(const Duration(milliseconds: 400), () => _load(url));
  }

  Future<void> _load(String url) async {
    _set(null, loading: true);
    final p = await _service.fetch(url);
    if (!mounted || _url != url || url == _dismissedUrl) return;
    _set(p, loading: false);
  }

  void _set(LinkPreview? p, {required bool loading}) {
    final changed = p != _preview;
    if (!mounted) return;
    setState(() {
      _preview = p;
      _loading = loading;
    });
    if (changed) widget.onChanged(p);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: LinkPreviewShimmer(),
      );
    }
    final p = _preview;
    if (p == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: LinkPreviewCard(
          preview: p,
          compact: true,
          onTap: () {},
          onRemove: () {
            _dismissedUrl = p.url;
            _set(null, loading: false);
          },
        ),
      ),
    );
  }
}

/// Grey skeleton of the compact card with a moving sheen, shown while the
/// link's details are being fetched.
class LinkPreviewShimmer extends StatefulWidget {
  const LinkPreviewShimmer({super.key});

  @override
  State<LinkPreviewShimmer> createState() => _LinkPreviewShimmerState();
}

class _LinkPreviewShimmerState extends State<LinkPreviewShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFFE3E4E8),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
    return Semantics(
      label: 'Loading link preview',
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) => ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment(3 * _c.value - 2, 0),
              end: Alignment(3 * _c.value - 1, 0),
              colors: const [
                Color(0xFFE3E4E8),
                Color(0xFFF6F7F9),
                Color(0xFFE3E4E8),
              ],
            ).createShader(rect),
            child: child,
          ),
          child: Row(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFE3E4E8),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(0.35, 10),
                  const SizedBox(height: 8),
                  bar(0.95, 12),
                  const SizedBox(height: 6),
                  bar(0.7, 12),
                  const SizedBox(height: 8),
                  bar(0.5, 9),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
