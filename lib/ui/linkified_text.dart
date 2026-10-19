import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Message text with web links shown in [linkColor] (underlined) and opened
/// in the browser on tap.
class LinkifiedText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color linkColor;

  const LinkifiedText(this.text,
      {super.key, required this.style, required this.linkColor});

  static final RegExp _link = RegExp(
    r'((?:https?:\/\/|www\.)[^\s<>"]+[^\s<>".,;:!?)\]}])',
    caseSensitive: false,
  );

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _open(String raw) async {
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'https://$raw');
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final matches = LinkifiedText._link.allMatches(text).toList();
    if (matches.isEmpty) return Text(text, style: widget.style);

    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in matches) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      final r = TapGestureRecognizer()..onTap = () => _open(url);
      _recognizers.add(r);
      spans.add(TextSpan(
        text: url,
        recognizer: r,
        style: TextStyle(
          color: widget.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: widget.linkColor,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
