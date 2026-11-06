import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import '../state/transfers_model.dart';
import 'config.dart';
import 'constants.dart';
import 'protocol.dart';
import 'store.dart';
import 'util.dart';

class TransferServer {
  final Config cfg;
  final AppStore store;
  final PeersModel peers;
  final ChatsModel chats;
  final TransfersModel transfers;
  ServerSocket? _srv;

  TransferServer({
    required this.cfg,
    required this.store,
    required this.peers,
    required this.chats,
    required this.transfers,
  });

  Future<void> start() async {
    // If the default port is taken (e.g. a second instance on this machine),
    // walk up until we bind; the actual port is announced via discovery.
    Object? lastError;
    for (var i = 0; i < 256; i++) {
      final port = cfg.tcpPort + i;
      try {
        _srv = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        cfg.tcpPort = port;
        await cfg.save();
        lastError = null;
        break;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    if (_srv == null) throw lastError ?? const SocketException('no port');
    _srv!.listen((sock) {
      _handle(sock);
    }, onError: (_) {});
  }

  Future<void> stop() async {
    await _srv?.close();
  }

  Future<void> _handle(Socket sock) async {
    final reader = FrameReader(sock);
    String? peerId;
    try {
      while (true) {
        final h = await reader.readHeader(timeout: const Duration(seconds: 120));
        final type = h.header['type'] as String?;

        if (type == 'hello') {
          final id = h.header['id'] as String?;
          if (id == null || id.isEmpty) break;
          peerId = id;
          peers.upsertFromHello(
            id: id,
            name: (h.header['name'] as String?) ?? '未命名设备',
            platform: (h.header['platform'] as String?) ?? '',
            port: (h.header['port'] as int?) ?? K.tcpPort,
            address: sock.remoteAddress.address,
          );
        } else if (type == 'text' && peerId != null) {
          final msgId = h.header['msgId'] as String?;
          if (msgId == null) break;
          final payload =
              await reader.readPayload(h.payloadLen, timeout: const Duration(seconds: 30));
          final text = utf8.decode(payload, allowMalformed: true);
          chats.onIncoming(
            peerId,
            ChatMessage(
              id: msgId,
              outgoing: false,
              kind: MsgKind.text,
              text: text,
              ts: _ts(h.header['ts']),
              state: SendState.received,
            ),
          );
          _sendAck(sock, msgId, true);
        } else if (type == 'file' && peerId != null) {
          final msgId = h.header['msgId'] as String?;
          if (msgId == null) break;
          final name = sanitizeFileName((h.header['name'] as String?) ?? 'file');
          final size = (h.header['size'] as int?) ?? h.payloadLen;
          final ts = _ts(h.header['ts']);

          if (!cfg.autoAccept) {
            await for (final _ in reader.payloadStream(h.payloadLen)) {}
            _sendAck(sock, msgId, false, 'declined');
            continue;
          }

          final dir = cfg.effectiveDownloadDir(store);
          var target = _uniquePath(dir, name);
          final part = File('$target.part');
          final hashSink = _HashSink();
          final hashConv = sha256.startChunkedConversion(hashSink);
          final sink = part.openWrite();
          var got = 0;
          try {
            await for (final chunk in reader.payloadStream(h.payloadLen)) {
              sink.add(chunk);
              hashConv.add(chunk);
              got += chunk.length;
              if (size > 0) transfers.update(msgId, got / size);
            }
            await sink.flush();
            await sink.close();
          } catch (_) {
            try {
              await sink.close();
            } catch (_) {}
            try {
              part.deleteSync();
            } catch (_) {}
            break;
          }
          hashConv.close();

          if (got != size) {
            try {
              part.deleteSync();
            } catch (_) {}
            _sendAck(sock, msgId, false, 'corrupt');
            continue;
          }
          try {
            part.renameSync(target);
          } catch (_) {
            try {
              target = _uniquePath(dir, name);
              part.renameSync(target);
            } catch (_) {
              _sendAck(sock, msgId, false, 'io');
              continue;
            }
          }
          chats.onIncoming(
            peerId,
            ChatMessage(
              id: msgId,
              outgoing: false,
              kind: MsgKind.file,
              fileName: name,
              fileSize: size,
              filePath: target,
              sha256: hashSink.digest?.toString(),
              ts: ts,
              state: SendState.received,
            ),
          );
          transfers.remove(msgId);
          _sendAck(sock, msgId, true);
        } else {
          break; // unknown type or message before hello
        }
      }
    } catch (_) {
      // closed / timeout — normal session end
    } finally {
      try {
        await reader.close();
      } catch (_) {}
      sock.destroy();
    }
  }

  void _sendAck(Socket sock, String msgId, bool ok, [String? reason]) {
    try {
      sock.add(FrameWriter.encode({
        'type': 'ack',
        'msgId': msgId,
        'ok': ok,
        if (reason != null) 'reason': reason,
      }));
    } catch (_) {}
  }

  static DateTime _ts(dynamic v) =>
      v is int ? DateTime.fromMillisecondsSinceEpoch(v) : DateTime.now();

  String _uniquePath(Directory dir, String name) {
    var candidate = File(p.join(dir.path, name));
    if (!candidate.existsSync()) return candidate.path;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var i = 1;
    while (true) {
      candidate = File(p.join(dir.path, '$stem ($i)$ext'));
      if (!candidate.existsSync()) return candidate.path;
      i++;
    }
  }
}

class _HashSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
