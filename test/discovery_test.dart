import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/discovery.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/state/peers_model.dart';

void main() {
  test(
    'failed UDP startup recovers on retry and receives peer broadcasts',
    () async {
      final dir = await Directory.systemTemp.createTemp('lanchat_discovery_');
      final store = await AppStore.open(dir);
      final cfg = await Config.load(store.configFile);
      final peers = PeersModel(store);
      addTearDown(peers.dispose);
      addTearDown(() => dir.delete(recursive: true));
      final interfaces = (await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      )).where((i) => i.addresses.any((a) => a.isLoopback)).toList();
      expect(interfaces, isNotEmpty);
      final reservation = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final discoveryPort = reservation.port;
      reservation.close();
      var deny = true;
      var binds = 0;
      RawDatagramSocket? receiver;
      RawDatagramSocket? transmitter;
      final discovery = Discovery(
        cfg: cfg,
        peers: peers,
        port: discoveryPort,
        listInterfaces: () async => interfaces,
        bindSocket: (address, port) async {
          binds++;
          if (deny) throw const SocketException('permission denied');
          final socket = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            port,
          );
          if (port != 0) {
            receiver = socket;
          } else {
            transmitter = socket;
          }
          return socket;
        },
      );
      addTearDown(discovery.stop);
      await discovery.start();
      expect(discovery.ready, false);
      expect(discovery.lastError, contains('permission denied'));
      deny = false;
      await discovery.refresh();
      expect(discovery.ready, true);
      expect(discovery.lastError, isNull);
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(sender.close);
      sender.send(
        utf8.encode(
          jsonEncode({
            'proto': 1,
            'id': 'remote',
            'name': 'Test peer',
            'port': 38702,
          }),
        ),
        InternetAddress.loopbackIPv4,
        receiver!.port,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!peers.isOnline('remote') && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(peers.isOnline('remote'), true);
      expect(discovery.receivedPackets, 1);
      // A failed send is an async stream error in dart:io and closes that
      // socket. It must never close the separate discovery receiver.
      transmitter!.broadcastEnabled = false;
      transmitter!.send([1], InternetAddress('255.255.255.255'), discoveryPort);
      final failureDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (discovery.ready && DateTime.now().isBefore(failureDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(discovery.ready, false);
      expect(receiver!.port, discoveryPort);
      await discovery.refresh();
      expect(discovery.ready, true);
      final before = binds;
      await discovery.refresh();
      expect(binds, before); // Healthy sockets are retained.
      await discovery.refresh(force: true);
      expect(binds, greaterThan(before));
      expect(discovery.ready, true);
      await discovery.stop();
      final afterStop = binds;
      await discovery.refresh();
      expect(binds, afterStop);
    },
  );

  test('network enumeration errors do not abort application startup', () async {
    final dir = await Directory.systemTemp.createTemp('lanchat_discovery_');
    final store = await AppStore.open(dir);
    final cfg = await Config.load(store.configFile);
    final peers = PeersModel(store);
    addTearDown(peers.dispose);
    addTearDown(() => dir.delete(recursive: true));
    final discovery = Discovery(
      cfg: cfg,
      peers: peers,
      listInterfaces: () async =>
          throw const SocketException('network unavailable'),
    );
    addTearDown(discovery.stop);
    await discovery.start();
    expect(discovery.lastError, contains('network unavailable'));
    expect(discovery.ready, false);
  });
}
