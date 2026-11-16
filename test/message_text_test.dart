import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/message_text.dart';
import 'package:lanchat/core/protocol.dart';

void main() {
  test('code round trips indentation, blank lines, CRLF and nested fences', () {
    for (final code in [
      '  print("hello");\n\n',
      '\r\n  x\r\n',
      '```dart\nx\n```',
    ]) {
      expect(decodeCode(encodeCode(code)), code);
    }
    expect(decodeCode('```\n```'), '');
    expect(decodeCode(encodeCode('')), '');
    expect(decodeCode('plain text'), isNull);
    expect(decodeCode('```broken'), isNull);
  });

  test(
    'links preserve local ports, balanced parentheses and exclude punctuation',
    () {
      final links = messageLinks(
        '地址 http://192.168.1.20:8080/a?q=1。 '
        '(https://example.com/a(b))，www.example.com/test.',
      );
      expect(links.map((e) => e.uri.toString()), [
        'http://192.168.1.20:8080/a?q=1',
        'https://example.com/a(b)',
        'https://www.example.com/test',
      ]);
      expect(messageLinks('javascript:alert(1) file:///tmp/test'), isEmpty);
    },
  );

  test('protocol rejects payload sizes that cannot fit the wire format', () {
    expect(
      () => FrameWriter.encodeHeader({}, 0x100000000),
      throwsFormatException,
    );
    expect(() => FrameWriter.encodeHeader({}, -1), throwsFormatException);
  });
}
