import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'constants.dart';
import '../state/peers_model.dart';

/// UDP multicast discovery.
/// - one rx socket bound to anyIPv4:38701, joins the multicast group on every
///   physical interface (virtual adapters filtered out)
/// - one tx socket per interface address (multicastLoopback enabled, so
///   instances on the same machine see each other)
/// - subnet-directed broadcast as a fallback for APs that drop multicast
class Discovery {
  final Config cfg;
  final PeersModel peers;

  RawDatagramSocket? _rx;
  final List<RawDatagramSocket> _tx = [];
  Timer? _timer;

  Discovery({required this.cfg, required this.peers});

  static const _virtualAdapterKeywords = [
    'vethernet', 'virtualbox', 'vmware', 'loopback', 'tap-', 'tun',
    'wsl', 'docker', 'hyper-v', 'tailscale', 'zerotier', 'awdl',
    'utun', 'llw', 'bridge', 'bluetooth', 'loopbackpseudointerface',
  ];

  Future<void> start() async {
    try {
      _rx = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        K.discoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
    } on SocketException {
      // port taken by another instance on this machine (they share discovery)
    }
    _rx?.broadcastEnabled = true;
    final group = InternetAddress(K.multicastGroup);
    for (final ifc in await _physicalInterfaces()) {
      try {
        _rx?.joinMulticast(group, ifc);
      } catch (_) {}
    }
    _rx?.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = _rx?.receive();
      if (dg != null) _onPacket(dg);
    });

    for (final ifc in await _physicalInterfaces()) {
      for (final addr in ifc.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        try {
          final s = await RawDatagramSocket.bind(addr, 0, reuseAddress: true);
          s.multicastLoopback = true;
          _tx.add(s);
        } catch (_) {}
      }
    }

    await _announce();
    _timer = Timer.periodic(K.announceInterval, (_) => _announce());
  }

  void _onPacket(Datagram dg) {
    try {
      final j = jsonDecode(utf8.decode(dg.data));
      if (j is! Map || j['proto'] != K.protoVersion) return;
      final id = j['id'];
      if (id is! String || id.isEmpty || id == cfg.deviceId) return;
      peers.upsertFromAnnounce(
        id: id,
        name: (j['name'] as String?) ?? '未命名设备',
        platform: (j['platform'] as String?) ?? '',
        port: (j['port'] as int?) ?? K.tcpPort,
        address: dg.address.address,
      );
    } catch (_) {}
  }

  Uint8List _payload() => Uint8List.fromList(utf8.encode(jsonEncode({
        'proto': K.protoVersion,
        'id': cfg.deviceId,
        'name': cfg.nickname,
        'platform': cfg.platformLabel,
        'port': cfg.tcpPort,
      })));

  Future<void> _announce() async {
    final payload = _payload();
    final group = InternetAddress(K.multicastGroup);
    final broadcast = InternetAddress('255.255.255.255');
    for (final s in _tx) {
      try {
        s.send(payload, group, K.discoveryPort);
      } catch (_) {}
      final a = s.address;
      if (a.type == InternetAddressType.IPv4) {
        final parts = a.address.split('.');
        if (parts.length == 4) {
          parts[3] = '255';
          try {
            s.send(payload, InternetAddress(parts.join('.')), K.discoveryPort);
          } catch (_) {}
        }
      }
    }
    try {
      _rx?.send(payload, broadcast, K.discoveryPort);
    } catch (_) {}
  }

  void announceNow() => _announce();

  /// Android can silently drop group membership while the app is backgrounded
  /// or the screen is off; re-join on resume so we keep hearing announces.
  Future<void> rejoinMulticast() async {
    final group = InternetAddress(K.multicastGroup);
    for (final ifc in await _physicalInterfaces()) {
      try {
        _rx?.joinMulticast(group, ifc);
      } catch (_) {}
    }
  }

  Future<List<NetworkInterface>> _physicalInterfaces() async {
    final list = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    return list.where((i) {
      final n = i.name.toLowerCase();
      return !_virtualAdapterKeywords.any((b) => n.contains(b));
    }).toList();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _rx?.close();
    for (final s in _tx) {
      s.close();
    }
    _tx.clear();
  }
}
