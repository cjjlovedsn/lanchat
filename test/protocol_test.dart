import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/protocol.dart';

void main() {
  test('frame roundtrip in one chunk', () async {
    final payload = Uint8List.fromList(utf8.encode('你好 lanchat'));
    final bytes = FrameWriter.encode({'type': 'text', 'msgId': 'm1'}, payload);
    final reader = FrameReader(Stream.value(bytes));
    final h = await reader.readHeader();
    expect(h.header['msgId'], 'm1');
    expect(h.header['type'], 'text');
    expect(h.payloadLen, payload.length);
    final got = await reader.readPayload(h.payloadLen);
    expect(utf8.decode(got), '你好 lanchat');
  });

  test('frames survive arbitrary chunk boundaries', () async {
    final payload = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final a = FrameWriter.encode({'type': 'file', 'size': 5000}, payload);
    final b = FrameWriter.encode({'type': 'ack', 'ok': true});
    final all = Uint8List.fromList([...a, ...b]);
    final chunks = <Uint8List>[
      for (var i = 0; i < all.length; i += 3)
        Uint8List.sublistView(
            all, i, i + 3 > all.length ? all.length : i + 3)
    ];
    final reader = FrameReader(Stream.fromIterable(chunks));

    final h1 = await reader.readHeader();
    expect(h1.header['type'], 'file');
    expect(h1.payloadLen, payload.length);
    final buf = BytesBuilder();
    await for (final c in reader.payloadStream(h1.payloadLen)) {
      buf.add(c);
    }
    expect(buf.toBytes(), equals(payload));

    final h2 = await reader.readHeader();
    expect(h2.header['ok'], true);
    expect(h2.payloadLen, 0);
  });

  test('header rejects nonsense length', () async {
    final bad = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]);
    final reader = FrameReader(Stream.value(bad));
    expect(() => reader.readHeader(),
        throwsA(isA<SocketException>()));
  });

  test('closed stream throws', () async {
    final reader =
        FrameReader(Stream<Uint8List>.fromIterable(const []));
    expect(() => reader.readHeader(), throwsA(isA<SocketException>()));
  });
}
