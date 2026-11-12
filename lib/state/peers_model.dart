import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/store.dart';
import '../models/peer.dart';

/// Known peers + live online state.
/// Rising online edge (announce or hello seen) fires [onPeerOnline],
/// which the outbox uses to start flushing queued messages.
class PeersModel extends ChangeNotifier {
  final AppStore store;
  final Map<String, Peer> peers = {};
  final Set<String> _online = {};
  Timer? _sweep;
  Timer? _persistDebounce;
  void Function(String peerId)? onPeerOnline;

  PeersModel(this.store);

  Future<void> start() async {
    final j = store.readJson(store.stateFile);
    final list = j?['peers'] as List?;
    if (list != null) {
      for (final e in list) {
        try {
          final p = Peer.fromJson(e as Map<String, dynamic>);
          peers[p.id] = p;
        } catch (_) {}
      }
    }
    _sweep = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Peer? byId(String id) => peers[id];

  bool isOnline(String id) => _online.contains(id);

  /// Drops a known peer (e.g. a stale ghost after the other side
  /// reinstalled and got a new device id). History is kept.
  void removePeer(String id) {
    if (peers.remove(id) == null) return;
    _online.remove(id);
    _persist();
    notifyListeners();
  }

  void upsertFromAnnounce({
    required String id,
    required String name,
    required String platform,
    required int port,
    required String address,
  }) =>
      _upsert(id: id, name: name, platform: platform, port: port, address: address);

  void upsertFromHello({
    required String id,
    required String name,
    required String platform,
    required int port,
    required String address,
  }) =>
      _upsert(id: id, name: name, platform: platform, port: port, address: address);

  void _upsert({
    required String id,
    required String name,
    required String platform,
    required int port,
    required String address,
  }) {
    var p = peers[id];
    if (p == null) {
      p = Peer(
        id: id,
        name: name,
        platform: platform,
        port: port,
        address: address,
        lastSeen: DateTime.now(),
      );
      peers[id] = p;
    } else {
      p.name = name;
      p.platform = platform;
      p.port = port;
      p.address = address;
      p.lastSeen = DateTime.now();
    }
    if (p.isOnline && !_online.contains(id)) {
      _online.add(id);
      onPeerOnline?.call(id);
    }
    _schedulePersist();
    notifyListeners();
  }

  void _tick() {
    var changed = false;
    final now = DateTime.now();
    for (final p in peers.values) {
      if (_online.contains(p.id) &&
          now.difference(p.lastSeen) > K.offlineAfter) {
        _online.remove(p.id);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedulePersist();
    }
  }

  List<Peer> get sorted {
    final l = peers.values.toList();
    l.sort((a, b) {
      final oa = _online.contains(a.id);
      final ob = _online.contains(b.id);
      if (oa != ob) return oa ? -1 : 1;
      return b.lastSeen.compareTo(a.lastSeen);
    });
    return l;
  }

  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 2), _persist);
  }

  void _persist() {
    try {
      AppStore.writeAtomic(
        store.stateFile,
        jsonEncode({'peers': [for (final p in peers.values) p.toJson()]}),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _sweep?.cancel();
    _persistDebounce?.cancel();
    super.dispose();
  }
}
