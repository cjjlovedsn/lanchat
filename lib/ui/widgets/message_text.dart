import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/message_text.dart';

class MessageText extends StatefulWidget {
  final String text;
  final Color color;
  const MessageText({super.key, required this.text, required this.color});

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clearRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接，请复制后在浏览器中打开')));
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final code = decodeCode(widget.text);
    final content = code ?? widget.text;
    final style = TextStyle(fontSize: 14, height: 1.45, color: widget.color);
    Widget body;
    if (code != null) {
      body = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          code,
          style: style.copyWith(fontFamily: 'monospace'),
        ),
      );
    } else {
      final spans = <TextSpan>[];
      var offset = 0;
      for (final link in messageLinks(content)) {
        spans.add(TextSpan(text: content.substring(offset, link.start)));
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _open(link.uri);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: content.substring(link.start, link.end),
            style: const TextStyle(
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
            recognizer: recognizer,
            mouseCursor: SystemMouseCursors.click,
          ),
        );
        offset = link.end;
      }
      spans.add(TextSpan(text: content.substring(offset)));
      body = SelectableText.rich(TextSpan(style: style, children: spans));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (code != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('代码', style: style.copyWith(fontSize: 11)),
          ),
        body,
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: code != null ? '复制代码' : '复制全文',
            icon: Icon(Icons.copy_outlined, size: 16, color: widget.color),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: content));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
