import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/store.dart';
import '../models/message.dart';

/// Chat history (persisted per peer as JSONL) + unread counters.
/// Pending outgoing messages are NOT stored here — they live in the Outbox
/// and the UI merges both via [mergedChatView].
class ChatsModel extends ChangeNotifier {
  final AppStore store;
  final Map<String, List<ChatMessage>> _history = {};
  final Map<String, int> unread = {};
  String? activePeerId;

  ChatsModel(this.store);

  /// Rebuild the chat UI whenever pending messages change too.
  void attachPending(Listenable pending) {
    pending.addListener(notifyListeners);
  }

  Future<void> load() async {
    final u = store.readJson(store.unreadFile);
    (u?['unread'] as Map?)?.forEach((k, v) {
      if (k is String && v is int) unread[k] = v;
    });
    try {
      for (final f in store.historyDir.listSync()) {
        if (f is! File || !f.path.endsWith('.jsonl')) continue;
        final peerId = p.basenameWithoutExtension(f.path);
        final list = <ChatMessage>[];
        for (final line in f.readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          try {
            list.add(ChatMessage.fromJson(jsonDecode(line) as Map<String, dynamic>));
          } catch (_) {}
        }
        _history[peerId] = list;
      }
    } catch (_) {}
  }

  List<ChatMessage> historyFor(String peerId) =>
      List<ChatMessage>.of(_history[peerId] ?? const []);

  /// Dedup by msgId: a resend after a lost ack must not duplicate history.
  void onIncoming(String peerId, ChatMessage msg) {
    final list = _history.putIfAbsent(peerId, () => []);
    if (list.any((m) => m.id == msg.id)) return;
    list.add(msg);
    store.appendHistory(peerId, msg.toJson());
    if (activePeerId != peerId) {
      unread[peerId] = (unread[peerId] ?? 0) + 1;
      _saveUnread();
    }
    notifyListeners();
  }

  void recordAck(String peerId, ChatMessage msg) {
    final list = _history.putIfAbsent(peerId, () => []);
    if (list.any((m) => m.id == msg.id)) return;
    list.add(msg);
    store.appendHistory(peerId, msg.toJson());
    notifyListeners();
  }

  void openChat(String peerId) {
    activePeerId = peerId;
    unread[peerId] = 0;
    _saveUnread();
    notifyListeners();
  }

  int get totalUnread => unread.values.fold(0, (a, b) => a + b);

  void _saveUnread() {
    try {
      AppStore.writeAtomic(store.unreadFile, jsonEncode({'unread': unread}));
    } catch (_) {}
  }
}

/// History + pending outbox items, ordered by ts (stable tiebreak so an
/// acked message keeps its place relative to still-pending ones).
List<ChatMessage> mergedChatView(
    List<ChatMessage> history, List<ChatMessage> pending) {
  final all = <(ChatMessage, int)>[
    for (final (i, m) in history.indexed) (m, i),
    for (final (i, m) in pending.indexed) (m, i + (1 << 30)),
  ];
  all.sort((a, b) {
    final c = a.$1.ts.compareTo(b.$1.ts);
    if (c != 0) return c;
    return a.$2.compareTo(b.$2);
  });
  return [for (final e in all) e.$1];
}
