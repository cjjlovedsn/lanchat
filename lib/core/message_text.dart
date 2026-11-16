/// Code is transported as a fenced plain-text message, compatible with older
/// clients. Pick a fence longer than any backtick run in the original code.
String encodeCode(String text) {
  var count = 3;
  for (final match in RegExp(r'`+').allMatches(text)) {
    if (match.group(0)!.length >= count) count = match.group(0)!.length + 1;
  }
  final fence = '`' * count;
  return '$fence\n$text\n$fence';
}

String? decodeCode(String text) {
  final match = RegExp(r'^(`{3,})([^\n`]*)\n').firstMatch(text);
  if (match == null) return null;
  final suffix = '\n${match.group(1)}';
  if (!text.endsWith(suffix)) return null;
  final end = text.length - suffix.length;
  if (end == match.end - 1) return '';
  if (end < match.end) return null;
  return text.substring(match.end, end);
}

class MessageLink {
  final int start;
  final int end;
  final Uri uri;
  const MessageLink(this.start, this.end, this.uri);
}

List<MessageLink> messageLinks(String text) {
  final result = <MessageLink>[];
  final pattern = RegExp(
    r'''(?:https?://|www\.)[^\s<>"'`，。！？；、（）【】]+''',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(text)) {
    var value = match.group(0)!;
    while (value.isNotEmpty) {
      final last = value[value.length - 1];
      final unbalanced = {')': '(', ']': '[', '}': '{'};
      final open = unbalanced[last];
      if ('.!?,;:'.contains(last) ||
          (open != null &&
              last.allMatches(value).length > open.allMatches(value).length)) {
        value = value.substring(0, value.length - 1);
      } else {
        break;
      }
    }
    final uri = Uri.tryParse(
      value.toLowerCase().startsWith('www.') ? 'https://$value' : value,
    );
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      continue;
    }
    result.add(MessageLink(match.start, match.start + value.length, uri));
  }
  return result;
}
