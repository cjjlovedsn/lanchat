// Standalone protocol client for E2E-testing a running LanChat instance.
//
//   dart run tool/e2e_client.dart send <host> <port>
//     Connect like a real peer, push one text + one file, expect acks.
//
//   dart run tool/e2e_client.dart serve <tcpPort>
//     Announce ourselves over UDP so the app discovers this "peer", then
//     accept the app's outbox-flush connection, receive hello/text/file
//     frames and ack each one. Exits after 12s of silence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const peerId = 'e2e-tester-01';
const peerName = 'E2E测试员';

Uint8List _u32(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xff
  ..[1] = (v >> 16) & 0xff
  ..[2] = (v >> 8) & 0xff
  ..[3] = v & 0xff;

Uint8List frame(Map<String, dynamic> header, [List<int>? payload]) {
  final json = utf8.encode(jsonEncode(header));
  final p = payload ?? const [];
  return Uint8List.fromList(
      [..._u32(json.length), ...json, ..._u32(p.length), ...p]);
}

class FrameSock {
  final Socket sock;
  final StreamIterator<Uint8List> _it;
  final List<int> _buf = [];

  FrameSock(this.sock) : _it = StreamIterator(sock);

  Future<Map<String, dynamic>?> readFrame(
      [Duration timeout = const Duration(seconds: 15)]) async {
    Future<Map<String, dynamic>?> read() async {
      while (true) {
        if (_buf.length >= 8) {
          final jl = _bytes(_buf, 0);
          final pl = _bytes(_buf, 4 + jl);
          if (jl > 0 && jl < 1024 * 1024 && _buf.length >= 8 + jl + pl) {
            final header =
                jsonDecode(utf8.decode(_buf.sublist(4, 4 + jl))) as Map;
            final payload = _buf.sublist(8 + jl, 8 + jl + pl);
            _buf.removeRange(0, 8 + jl + pl);
            return {'header': header, 'payload': payload};
          }
        }
        if (!await _it.moveNext()) return null;
        _buf.addAll(_it.current);
      }
    }

    return read().timeout(timeout, onTimeout: () => null);
  }

  static int _bytes(List<int> b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}

Future<void> sendMode(String host, int port) async {
  final sock = await Socket.connect(host, port,
      timeout: const Duration(seconds: 5));
  final fs = FrameSock(sock);
  sock.add(frame({
    'type': 'hello',
    'id': peerId,
    'name': peerName,
    'platform': 'e2e',
    'port': 0,
  }));
  final textMsgId = 'e2e-text-${DateTime.now().millisecondsSinceEpoch}';
  final textPayload = utf8.encode('E2E 消息：你好，这是协议级端到端测试 $textMsgId');
  sock.add(frame({'type': 'text', 'msgId': textMsgId, 'ts': _nowMs()},
      textPayload));
  await sock.flush();

  final fileBytes = utf8.encode('E2E file payload $textMsgId\n'
      'line2: 局域网传文件测试\n');
  final fileMsgId = 'e2e-file-${DateTime.now().millisecondsSinceEpoch}';
  final tmp = File.fromUri(Platform.script.resolve('e2e_payload.txt'));
  await tmp.writeAsBytes(fileBytes);
  sock.add(frame({
    'type': 'file',
    'msgId': fileMsgId,
    'ts': _nowMs(),
    'name': 'e2e_payload.txt',
    'size': fileBytes.length,
    'sha256': sha256.convert(fileBytes).toString(),
  }, fileBytes));
  await sock.flush();

  final want = {textMsgId, fileMsgId};
  final got = <String, bool>{};
  while (got.length < 2) {
    final f = await fs.readFrame(const Duration(seconds: 20));
    if (f == null) break;
    final h = f['header'] as Map;
    if (h['type'] != 'ack') continue;
    final id = h['msgId'] as String?;
    if (id != null && want.contains(id)) {
      got[id] = h['ok'] == true;
      stderr.writeln('ack $id ok=${h['ok']} reason=${h['reason']}');
    }
  }
  await sock.close();
  final ok = got.length == 2 && got.values.every((v) => v);
  stderr.writeln('SEND-MODE ${ok ? 'PASS' : 'FAIL'} '
      '(text=${got[textMsgId]} file=${got[fileMsgId]})');
  stderr.writeln('IDS: $textMsgId $fileMsgId');
  exit(ok ? 0 : 1);
}

Future<void> serveMode(int tcpPort) async {
  final srv = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
  stderr.writeln('serve: tcp $tcpPort, announcing as $peerId');

  final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
      reuseAddress: true);
  udp.multicastLoopback = true;
  final payload = Uint8List.fromList(utf8.encode(jsonEncode({
        'proto': 1,
        'id': peerId,
        'name': peerName,
        'platform': 'e2e',
        'port': tcpPort,
      })));
  final group = InternetAddress('224.0.0.198');
  final bcast = InternetAddress('255.255.255.255');
  final targets = <InternetAddress>[group, bcast];
  for (final ifc in await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLinkLocal: false)) {
    for (final a in ifc.addresses) {
      final parts = a.address.split('.');
      if (parts.length == 4) {
        parts[3] = '255';
        targets.add(InternetAddress(parts.join('.')));
      }
    }
  }
  final announcer = Timer.periodic(const Duration(seconds: 1), (_) {
    for (final t in targets) {
      try {
        udp.send(payload, t, 38701);
      } catch (_) {}
    }
  });

  var gotMessages = 0;
  var allFramesValid = true;
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  final sub = srv.listen((sock) async {
    stderr.writeln('serve: connection from ${sock.remoteAddress.address}');
    final fs = FrameSock(sock);
    try {
      while (true) {
        final f = await fs.readFrame(
            const Duration(seconds: 12));
        if (f == null) break;
        final h = f['header'] as Map;
        final type = h['type'];
        if (type == 'hello') {
          stderr.writeln('serve: hello from ${h['name']} (${h['id']})');
        } else if (type == 'text' || type == 'file') {
          gotMessages++;
          var body = '';
          var valid = true;
          if (type == 'text') {
            body = utf8.decode(f['payload'] as List<int>);
          } else {
            final payload = f['payload'] as List<int>;
            final declared = (h['size'] as num?)?.toInt() ?? -1;
            final digest = sha256.convert(payload).toString();
            final lenOk = payload.length == declared;
            final shaOk = digest == h['sha256'];
            valid = lenOk && shaOk;
            body = '(file ${h['name']} declared=${declared}B '
                'payloadLen=${payload.length} shaOk=$shaOk)';
          }
          stderr.writeln('serve: $type ${h['msgId']} valid=$valid $body');
          if (!valid) allFramesValid = false;
          sock.add(frame({
            'type': 'ack',
            'msgId': h['msgId'],
            'ok': valid,
            if (!valid) 'reason': 'e2e-mismatch',
          }));
          await sock.flush();
        }
      }
    } catch (_) {}
    sock.destroy();
  });

  while (gotMessages == 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  // extra grace for more queued messages
  await Future<void>.delayed(const Duration(seconds: 14));
  announcer.cancel();
  await sub.cancel();
  await srv.close();
  final ok = gotMessages > 0 && allFramesValid;
  stderr.writeln('SERVE-MODE ${ok ? 'PASS' : 'FAIL'} '
      '(messages=$gotMessages allFramesValid=$allFramesValid)');
  exit(ok ? 0 : 1);
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: e2e_client.dart send <host> <port> | serve <port>');
    exit(2);
  }
  switch (args[0]) {
    case 'send':
      sendMode(args[1], int.parse(args[2]));
    case 'serve':
      serveMode(int.parse(args[1]));
    default:
      stderr.writeln('unknown mode ${args[0]}');
      exit(2);
  }
}
