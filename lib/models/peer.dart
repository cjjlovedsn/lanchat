import '../core/constants.dart';

class Peer {
  final String id;
  String name;
  String platform;
  int port;
  String? address;
  DateTime lastSeen;

  Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.port,
    this.address,
    required this.lastSeen,
  });

  bool get isOnline => DateTime.now().difference(lastSeen) <= K.offlineAfter;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'port': port,
        'address': address,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '未知设备',
        platform: (j['platform'] as String?) ?? '',
        port: (j['port'] as int?) ?? K.tcpPort,
        address: j['address'] as String?,
        lastSeen: DateTime.tryParse((j['lastSeen'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
