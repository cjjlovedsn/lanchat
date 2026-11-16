import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'constants.dart';
import '../state/peers_model.dart';

typedef DiscoveryBinder =
    Future<RawDatagramSocket> Function(InternetAddress address, int port);

/// Rebuilds discovery sockets when permissions or network interfaces change.
class Discovery extends ChangeNotifier {
  final Config cfg;
  final PeersModel peers;
  final DiscoveryBinder? bindSocket;
  final Future<List<NetworkInterface>> Function()? listInterfaces;
  final void Function(String)? onDiagnostic;
  final int port;
  RawDatagramSocket? _rx;
  final List<_AnnouncementSocket> _tx = [];
  final Map<RawDatagramSocket, StreamSubscription<RawSocketEvent>>
  _txSubscriptions = {};
  Timer? _timer;
  bool _running = false;
  bool _refreshing = false;
  String _signature = '';
  List<String> addresses = [];
  String? lastError;
  int receivedPackets = 0;
  bool get ready => _rx != null && _tx.isNotEmpty;

  Discovery({
    required this.cfg,
    required this.peers,
    this.bindSocket,
    this.listInterfaces,
    this.onDiagnostic,
    this.port = K.discoveryPort,
  });

  static const _virtualAdapterKeywords = [
    'vethernet',
    'virtualbox',
    'vmware',
    'loopback',
    'tap-',
    'tun',
    'wsl',
    'docker',
    'hyper-v',
    'tailscale',
    'zerotier',
    'awdl',
    'utun',
    'llw',
    'bridge',
    'bluetooth',
    'loopbackpseudointerface',
  ];

  void _log(String message) {
    debugPrint('[discovery] $message');
    onDiagnostic?.call('${DateTime.now().toIso8601String()} $message');
  }

  Future<RawDatagramSocket> _bind(InternetAddress address, int port) {
    if (bindSocket != null) return bindSocket!(address, port);
    return RawDatagramSocket.bind(
      address,
      port,
      reuseAddress: true,
      reusePort: !Platform.isWindows,
    );
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await refresh();
    _timer = Timer.periodic(K.announceInterval, (_) => refresh());
  }

  Future<void> refresh({bool force = false}) async {
    if (!_running || _refreshing) return;
    _refreshing = true;
    final errors = <String>[];
    try {
      final interfaces = await _physicalInterfaces();
      if (!_running) return;
      final nextAddresses = [
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      ]..sort();
      final signature = interfaces
          .map(
            (i) => '${i.index}:${i.addresses.map((a) => a.address).join(',')}',
          )
          .join(';');
      addresses = nextAddresses;
      if (force || signature != _signature) {
        _closeSockets();
        _signature = signature;
      }
      if (_rx == null) {
        try {
          final rx = await _bind(InternetAddress.anyIPv4, port);
          if (!_running) {
            rx.close();
            return;
          }
          rx.broadcastEnabled = true;
          rx.multicastLoopback = true;
          _rx = rx;
          rx.listen(
            (event) {
              if (event == RawSocketEvent.read) {
                Datagram? packet;
                while ((packet = rx.receive()) != null) {
                  _onPacket(packet!);
                }
              } else if (event == RawSocketEvent.closed && identical(_rx, rx)) {
                _rx = null;
              }
            },
            onError: (Object error) {
              _log('UDP receive: $error');
              rx.close();
              if (identical(_rx, rx)) _rx = null;
            },
          );
          _log('Listening UDP :$port');
        } catch (error) {
          errors.add('无法监听设备发现端口 $port：$error');
        }
      }
      final group = InternetAddress(K.multicastGroup);
      for (final interface in interfaces) {
        if (_rx != null) {
          try {
            _rx!.joinMulticast(group, interface);
          } catch (_) {
            // Joining an already joined group is harmless; broadcasts still work.
          }
        }
        for (final address in interface.addresses) {
          for (final target in _targetsFor(address)) {
            if (_tx.any(
              (sender) =>
                  sender.source == address.address &&
                  sender.target.address == target.address,
            )) {
              continue;
            }
            RawDatagramSocket? candidate;
            try {
              final tx = await _bind(address, 0);
              candidate = tx;
              if (!_running) {
                tx.close();
                return;
              }
              tx.broadcastEnabled = true;
              tx.multicastLoopback = true;
              tx.writeEventsEnabled = false;
              // Separate destinations: a failed subnet broadcast must not
              // close the multicast sender (and vice versa).
              final sender = _AnnouncementSocket(tx, address.address, target);
              _tx.add(sender);
              _txSubscriptions[tx] = tx.listen(
                (event) {
                  if (event == RawSocketEvent.read) {
                    while (tx.receive() != null) {}
                  } else if (event == RawSocketEvent.closed) {
                    _tx.remove(sender);
                    _txSubscriptions.remove(tx);
                  }
                },
                onError: (Object error) {
                  _log('UDP ${address.address} -> ${target.address}: $error');
                  tx.close();
                  _tx.remove(sender);
                  _txSubscriptions.remove(tx);
                },
              );
              _log(
                'Sending through ${interface.name} ${address.address} -> ${target.address}',
              );
            } catch (error) {
              candidate?.close();
              errors.add('无法使用网卡 ${interface.name}：$error');
            }
          }
        }
      }

      if (interfaces.isEmpty) errors.add('没有可用的局域网 IPv4 网卡，请检查网络连接');
      final announceError = _announce();
      if (announceError != null) errors.add(announceError);
      final error = errors.isEmpty ? null : errors.join('\n');
      if (lastError != error && error != null) _log(error);
      lastError = error;
    } catch (error) {
      lastError = '自动发现初始化失败：$error';
      _log(lastError!);
    } finally {
      _refreshing = false;
      if (_running) notifyListeners();
    }
  }

  void _onPacket(Datagram packet) {
    try {
      final data = jsonDecode(utf8.decode(packet.data));
      if (data is! Map || data['proto'] != K.protoVersion) return;
      final id = data['id'];
      final tcpPort = data['port'];
      if (id is! String ||
          id.isEmpty ||
          id == cfg.deviceId ||
          tcpPort is! int ||
          tcpPort < 1 ||
          tcpPort > 65535) {
        return;
      }
      receivedPackets++;
      peers.upsertFromAnnounce(
        id: id,
        name: data['name'] is String ? data['name'] as String : '未命名设备',
        platform: data['platform'] is String ? data['platform'] as String : '',
        port: tcpPort,
        address: packet.address.address,
      );
      notifyListeners();
    } catch (_) {}
  }

  Uint8List _payload() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'proto': K.protoVersion,
        'id': cfg.deviceId,
        'name': cfg.nickname,
        'platform': cfg.platformLabel,
        'port': cfg.tcpPort,
      }),
    ),
  );

  String? _announce() {
    final payload = _payload();
    var sent = 0;
    Object? lastFailure;
    // RawDatagramSocket.send reports OS failures asynchronously and closes
    // the socket. Keep the receiver read-only so a failed broadcast can never
    // disable discovery reception.
    for (final sender in _tx) {
      try {
        if (sender.socket.send(payload, sender.target, port) > 0) sent++;
      } catch (error) {
        lastFailure = error;
      }
    }
    _log('Heartbeat sent=$sent senders=${_tx.length} rx=${_rx != null}');
    if (sent == 0 && lastFailure != null) return '发现广播发送失败：$lastFailure';
    return null;
  }

  List<InternetAddress> _targetsFor(InternetAddress address) {
    if (address.isLoopback) return [address];
    final parts = address.address.split('.')..[3] = '255';
    return [
      InternetAddress(K.multicastGroup),
      InternetAddress(parts.join('.')),
    ];
  }

  void announceNow() => unawaited(refresh());
  Future<void> rejoinMulticast() => refresh(force: true);

  Future<List<NetworkInterface>> _physicalInterfaces() async {
    if (listInterfaces != null) return listInterfaces!();
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    return interfaces
        .where(
          (i) => !_virtualAdapterKeywords.any(
            (word) => i.name.toLowerCase().contains(word),
          ),
        )
        .toList();
  }

  String get report =>
      '局域网地址：${addresses.join(', ')}\n'
      '发现监听：${_rx != null ? '正常' : '未启动'}（UDP $port）\n'
      '发送网卡：${_tx.length}\n传输端口：${cfg.tcpPort}\n'
      '收到设备广播：$receivedPackets\n${lastError ?? '未检测到本机发现服务错误'}';

  void _closeSockets() {
    _rx?.close();
    _rx = null;
    for (final socket in _tx) {
      socket.socket.close();
    }
    for (final subscription in _txSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _txSubscriptions.clear();
    _tx.clear();
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _closeSockets();
  }
}

class _AnnouncementSocket {
  final RawDatagramSocket socket;
  final String source;
  final InternetAddress target;
  const _AnnouncementSocket(this.socket, this.source, this.target);
}
