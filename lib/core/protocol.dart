import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Wire format, big endian:
///   [u32 jsonLen][header JSON utf8][u32 payloadLen][payload bytes]
class FrameWriter {
  static Uint8List encode(Map<String, dynamic> header, [Uint8List? payload]) {
    final json = utf8.encode(jsonEncode(header));
    final out = BytesBuilder();
    out.add(_u32(json.length));
    out.add(json);
    out.add(_u32(payload?.length ?? 0));
    if (payload != null && payload.isNotEmpty) out.add(payload);
    return out.toBytes();
  }
}

Uint8List _u32(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xff
  ..[1] = (v >> 16) & 0xff
  ..[2] = (v >> 8) & 0xff
  ..[3] = v & 0xff;

class IncomingHeader {
  final Map<String, dynamic> header;
  final int payloadLen;
  const IncomingHeader(this.header, this.payloadLen);
}

/// Reads frames from a socket stream, buffering arbitrary chunk boundaries.
class FrameReader {
  final StreamIterator<Uint8List> _it;
  Uint8List _buf = Uint8List(0);
  int _off = 0;

  static const int _maxJsonLen = 1024 * 1024;

  FrameReader(Stream<Uint8List> stream) : _it = StreamIterator(stream);

  int get _avail => _buf.length - _off;

  void _compact() {
    if (_off > 0) {
      _buf = Uint8List.fromList(_buf.sublist(_off));
      _off = 0;
    }
  }

  Future<void> _ensure(int n, {Duration? timeout}) async {
    while (_avail < n) {
      var more = false;
      if (timeout == null) {
        more = await _it.moveNext();
      } else {
        try {
          more = await _it.moveNext().timeout(timeout);
        } on TimeoutException {
          throw const SocketException('frame read timeout');
        }
      }
      if (!more) throw const SocketException('stream closed');
      _compact();
      final bb = BytesBuilder(copy: false);
      bb.add(_buf);
      bb.add(_it.current);
      _buf = bb.toBytes();
    }
  }

  Uint8List _take(int n) {
    final r = Uint8List.sublistView(_buf, _off, _off + n);
    _off += n;
    return r;
  }

  int _readU32() {
    final b = _take(4);
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  }

  /// Reads the next frame header. Throws SocketException on close/timeout.
  Future<IncomingHeader> readHeader({Duration? timeout}) async {
    await _ensure(4, timeout: timeout);
    final jsonLen = _readU32();
    if (jsonLen <= 0 || jsonLen > _maxJsonLen) {
      throw const SocketException('bad header length');
    }
    await _ensure(jsonLen, timeout: timeout);
    Map<String, dynamic> header;
    try {
      header = jsonDecode(utf8.decode(_take(jsonLen))) as Map<String, dynamic>;
    } catch (_) {
      throw const SocketException('bad header json');
    }
    await _ensure(4, timeout: timeout);
    final payloadLen = _readU32();
    return IncomingHeader(header, payloadLen);
  }

  /// Small payloads (text, acks).
  Future<Uint8List> readPayload(int len, {Duration? timeout}) async {
    await _ensure(len, timeout: timeout);
    return Uint8List.fromList(_take(len));
  }

  /// Streams a payload without buffering it whole (file bodies).
  Stream<Uint8List> payloadStream(int len) async* {
    var remaining = len;
    while (remaining > 0) {
      if (_avail == 0) {
        await _ensure(1, timeout: const Duration(minutes: 10));
      }
      final take = math.min(remaining, _avail);
      yield Uint8List.fromList(_take(take));
      remaining -= take;
    }
  }

  Future<void> close() => _it.cancel();
}
