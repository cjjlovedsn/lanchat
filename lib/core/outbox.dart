import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import '../state/transfers_model.dart';
import 'store.dart';
import 'protocol.dart';
import 'transfer_client.dart';

class OutboxItem {
  final String msgId;
  final MsgKind kind;
  final String? text;
  final String? blobPath; // copy kept in outbox/files until acked
  final String? sourcePath; // original path (informational, for reveal)
  final String? fileName;
  final int fileSize;
  final DateTime ts;
  bool sending = false;

  OutboxItem({
    required this.msgId,
    required this.kind,
    required this.ts,
    this.text,
    this.blobPath,
    this.sourcePath,
    this.fileName,
    this.fileSize = 0,
  });

  Map<String, dynamic> toJson() => {
    'msgId': msgId,
    'kind': kind.name,
    'text': text,
    'blob': blobPath,
    'src': sourcePath,
    'name': fileName,
    'size': fileSize,
    'ts': ts.toIso8601String(),
  };

  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
    msgId: j['msgId'] as String,
    kind: j['kind'] == 'file' ? MsgKind.file : MsgKind.text,
    text: j['text'] as String?,
    blobPath: j['blob'] as String?,
    sourcePath: j['src'] as String?,
    fileName: j['name'] as String?,
    fileSize: j['size'] as int? ?? 0,
    ts: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Messages/files queued for offline peers. A send is always an enqueue
/// followed by a flush attempt; when the peer comes online the whole queue
/// is pushed in order and only removed after its ack.
class Outbox extends ChangeNotifier {
  final AppStore store;
  final PeersModel peers;
  final ChatsModel chats;
  final TransfersModel transfers;
  SessionOpener opener;
  final _uuid = const Uuid();

  final Map<String, List<OutboxItem>> _queues = {};
  final Set<String> _busy = {};
  Timer? _retry;

  Outbox({
    required this.store,
    required this.peers,
    required this.chats,
    required this.transfers,
    required this.opener,
  }) {
    _loadAll();
  }

  void _loadAll() {
    try {
      for (final f in store.outboxDir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        final peerId = p.basenameWithoutExtension(f.path);
        final j = store.readJson(f);
        final list = j?['items'] as List?;
        final items = <OutboxItem>[];
        for (final e in list ?? const []) {
          try {
            final it = OutboxItem.fromJson(e as Map<String, dynamic>);
            // blob gone (crashed mid-cleanup)? drop silently for files
            if (it.kind == MsgKind.file &&
                (it.blobPath == null || !File(it.blobPath!).existsSync())) {
              continue;
            }
            items.add(it);
          } catch (_) {}
        }
        if (items.isNotEmpty) _queues[peerId] = items;
      }
    } catch (_) {}
  }

  List<ChatMessage> viewFor(String peerId) => [
    for (final it in _queues[peerId] ?? const <OutboxItem>[])
      ChatMessage(
        id: it.msgId,
        outgoing: true,
        kind: it.kind,
        text: it.text,
        fileName: it.fileName,
        fileSize: it.fileSize,
        filePath: it.sourcePath,
        ts: it.ts,
        state: it.sending ? SendState.sending : SendState.pending,
      ),
  ];

  Future<void> sendText(String peerId, String text) async {
    final item = OutboxItem(
      msgId: _uuid.v4(),
      kind: MsgKind.text,
      text: text,
      ts: DateTime.now(),
    );
    _queues.putIfAbsent(peerId, () => []).add(item);
    await _persist(peerId);
    notifyListeners();
    unawaited(flushPeer(peerId));
  }

  Future<void> sendFile(String peerId, String sourcePath) async {
    final msgId = _uuid.v4();
    final blob = File(p.join(store.outboxFilesDir.path, msgId));
    try {
      final source = File(sourcePath);
      if (await source.length() > FrameWriter.maxPayloadLength) {
        throw const FileSystemException('单个文件必须小于 4 GiB');
      }
      await source.copy(blob.path);
    } catch (_) {
      if (await blob.exists()) await blob.delete();
      rethrow;
    }
    final size = await blob.length();
    final item = OutboxItem(
      msgId: msgId,
      kind: MsgKind.file,
      blobPath: blob.path,
      sourcePath: sourcePath,
      fileName: p.basename(sourcePath),
      fileSize: size,
      ts: DateTime.now(),
    );
    _queues.putIfAbsent(peerId, () => []).add(item);
    await _persist(peerId);
    notifyListeners();
    unawaited(flushPeer(peerId));
  }

  /// Removes queued items the user deleted from the chat view
  /// (also drops their file blobs so they are never sent).
  Future<void> remove(String peerId, Set<String> ids) async {
    final items = _queues[peerId];
    if (items == null || ids.isEmpty) return;
    final kept = <OutboxItem>[];
    for (final it in items) {
      if (ids.contains(it.msgId)) {
        if (!it.sending) _deleteBlob(it);
        transfers.remove(it.msgId);
      } else {
        kept.add(it);
      }
    }
    if (kept.length == items.length) return;
    if (kept.isEmpty) {
      _queues.remove(peerId);
    } else {
      _queues[peerId] = kept;
    }
    await _persist(peerId);
    notifyListeners();
  }

  Future<void> flushPeer(String peerId) async {
    if (_busy.contains(peerId)) return;
    final peer = peers.byId(peerId);
    final items = _queues[peerId];
    if (peer == null || items == null || items.isEmpty) return;
    if (!peers.isOnline(peerId)) return;

    _busy.add(peerId);
    OutboundSession? sess;
    final batch = List<OutboxItem>.of(items);
    try {
      sess = await opener(peer);
      if (sess == null) return;
      for (final it in batch) {
        // A user may have removed this item while a previous send was awaiting IO.
        if (!(_queues[peerId]?.contains(it) ?? false)) continue;
        it.sending = true;
        notifyListeners();
        final tsMs = it.ts.millisecondsSinceEpoch;
        if (it.kind == MsgKind.text) {
          await sess.sendText(msgId: it.msgId, text: it.text ?? '', tsMs: tsMs);
        } else {
          await sess.sendFile(
            msgId: it.msgId,
            name: it.fileName ?? p.basename(it.blobPath ?? 'file'),
            path: it.blobPath ?? '',
            tsMs: tsMs,
            onProgress: (f) => transfers.update(it.msgId, f),
          );
        }
        // Commit each ack before sending another file: later failures must not
        // roll back deliveries already confirmed by the receiver.
        final acks = await sess.collectAcks({it.msgId});
        final ack = acks[it.msgId];
        if (ack == null || (!ack.ok && ack.reason != 'declined')) break;
        final live = _queues[peerId];
        if (live != null && live.contains(it)) {
          chats.recordAck(
            peerId,
            ChatMessage(
              id: it.msgId,
              outgoing: true,
              kind: it.kind,
              text: it.text,
              fileName: it.fileName,
              fileSize: it.fileSize,
              filePath: it.sourcePath,
              ts: it.ts,
              state: ack.ok ? SendState.delivered : SendState.refused,
            ),
          );
          live.remove(it);
          if (live.isEmpty) _queues.remove(peerId);
          await _persist(peerId);
        }
        _deleteBlob(it);
        transfers.remove(it.msgId);
        notifyListeners();
      }
    } catch (_) {
      // Keep unacknowledged items persisted for the next retry.
    } finally {
      for (final it in batch) {
        it.sending = false;
        transfers.remove(it.msgId);
        if (!(_queues[peerId]?.contains(it) ?? false)) _deleteBlob(it);
      }
      try {
        await sess?.close();
      } finally {
        _busy.remove(peerId);
        notifyListeners();
      }
      // Items enqueued during this batch were never part of its snapshot.
      // Flush them immediately, but avoid a tight retry loop on failed items.
      final live = _queues[peerId];
      if (live != null &&
          live.isNotEmpty &&
          !live.any((it) => batch.contains(it))) {
        unawaited(flushPeer(peerId));
      }
    }
  }

  void _deleteBlob(OutboxItem it) {
    final b = it.blobPath;
    if (b == null) return;
    try {
      final f = File(b);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> _persist(String peerId) async {
    final f = store.outboxFile(peerId);
    final items = _queues[peerId];
    if (items == null || items.isEmpty) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    AppStore.writeAtomic(
      f,
      jsonEncode({
        'items': [for (final i in items) i.toJson()],
      }),
    );
  }

  /// Safety net: retry online peers with pending items (e.g. transient error).
  void startRetry() {
    _retry = Timer.periodic(const Duration(seconds: 15), (_) {
      for (final entry in _queues.entries.toList()) {
        if (!_busy.contains(entry.key) &&
            entry.value.isNotEmpty &&
            peers.isOnline(entry.key)) {
          unawaited(flushPeer(entry.key));
        }
      }
    });
  }

  int get pendingCount => _queues.values.fold(0, (s, l) => s + l.length);

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }
}
