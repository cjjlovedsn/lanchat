import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/peer.dart';
import 'config.dart';
import 'protocol.dart';

class SendReport {
  final String msgId;
  final bool ok;
  final String? reason;
  const SendReport(this.msgId, this.ok, {this.reason});
}

/// One TCP session that can push several messages, then collect their acks.
/// Abstract so the outbox can be unit-tested with a fake session.
abstract class OutboundSession {
  Future<void> sendText(
      {required String msgId, required String text, required int tsMs});
  Future<void> sendFile(
      {required String msgId,
      required String path,
      required int tsMs,
      required void Function(double) onProgress});
  Future<Map<String, SendReport>> collectAcks(Set<String> msgIds);
  Future<void> close();
}

typedef SessionOpener = Future<OutboundSession?> Function(Peer peer);

class TcpOutboundSession implements OutboundSession {
  final Socket _sock;
  final FrameReader _reader;

  TcpOutboundSession._(this._sock, this._reader);

  static Future<OutboundSession?> connect(Peer peer, Config cfg) async {
    final addr = peer.address;
    if (addr == null) return null;
    Socket sock;
    try {
      sock = await Socket.connect(addr, peer.port,
          timeout: const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
    final s = TcpOutboundSession._(sock, FrameReader(sock));
    sock.add(FrameWriter.encode({
      'type': 'hello',
      'id': cfg.deviceId,
      'name': cfg.nickname,
      'platform': cfg.platformLabel,
      'port': cfg.tcpPort,
    }));
    return s;
  }

  @override
  Future<void> sendText(
      {required String msgId, required String text, required int tsMs}) async {
    _sock.add(FrameWriter.encode({'type': 'text', 'msgId': msgId, 'ts': tsMs},
        Uint8List.fromList(utf8.encode(text))));
    await _sock.flush();
  }

  @override
  Future<void> sendFile(
      {required String msgId,
      required String path,
      required int tsMs,
      required void Function(double) onProgress}) async {
    final f = File(path);
    final size = await f.length();
    final digest = await sha256.bind(f.openRead()).last;
    _sock.add(FrameWriter.encode({
      'type': 'file',
      'msgId': msgId,
      'ts': tsMs,
      'name': p.basename(path),
      'size': size,
      'sha256': digest.toString(),
    }));
    var sent = 0;
    await for (final chunk in f.openRead()) {
      _sock.add(chunk);
      sent += chunk.length;
      onProgress(sent / size);
    }
    await _sock.flush();
  }

  @override
  Future<Map<String, SendReport>> collectAcks(Set<String> msgIds) async {
    final out = <String, SendReport>{};
    try {
      while (out.length < msgIds.length) {
        final h = await _reader.readHeader(timeout: const Duration(seconds: 90));
        if (h.header['type'] != 'ack') continue;
        final id = h.header['msgId'] as String?;
        if (id == null || !msgIds.contains(id) || out.containsKey(id)) continue;
        out[id] =
            SendReport(id, h.header['ok'] == true, reason: h.header['reason'] as String?);
      }
    } catch (_) {
      // closed / timeout: missing ids count as not delivered
    }
    return out;
  }

  @override
  Future<void> close() async {
    _sock.destroy();
  }
}
