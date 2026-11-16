import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/discovery.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';
import 'package:lanchat/ui/app_theme.dart';
import 'package:lanchat/ui/peer_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('peer order is by name and immune to heartbeat lastSeen churn', () async {
    final dir = await Directory.systemTemp.createTemp('lanchat_peers_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = await AppStore.open(dir);
    final peers = PeersModel(store);
    addTearDown(peers.dispose);
    // Announce in an order that would sort differently by lastSeen.
    for (final entry in [
      ['b', 'Zed'],
      ['a', 'amy'],
      ['c', 'Bob'],
    ]) {
      peers.upsertFromAnnounce(
        id: entry[0],
        name: entry[1],
        platform: 'windows',
        port: 1,
        address: '127.0.0.1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    String names() => peers.sorted.map((p) => p.name).join(',');
    expect(names(), 'amy,Bob,Zed');
    // Heartbeats keep arriving in arbitrary order; list must not reshuffle.
    peers.upsertFromAnnounce(
      id: 'c',
      name: 'Bob',
      platform: 'windows',
      port: 1,
      address: '127.0.0.1',
    );
    peers.upsertFromAnnounce(
      id: 'a',
      name: 'amy',
      platform: 'windows',
      port: 1,
      address: '127.0.0.1',
    );
    expect(names(), 'amy,Bob,Zed');
  });

  testWidgets('tapping the own profile card renames this device', (
    tester,
  ) async {
    late Directory dir;
    late AppStore store;
    late Config config;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lanchat_owncard_');
      store = await AppStore.open(dir);
      config = await Config.load(store.configFile);
    });
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final peers = PeersModel(store);
    final chats = ChatsModel(store);
    addTearDown(peers.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppStore>.value(value: store),
          ChangeNotifierProvider<Config>.value(value: config),
          ChangeNotifierProvider<PeersModel>.value(value: peers),
          ChangeNotifierProvider<ChatsModel>.value(value: chats),
          Provider<Discovery?>.value(value: null),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            AppAccent.ocean,
            Brightness.light,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 500,
              child: PeerListPanel(selectedPeerId: null, onSelect: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(config.nickname));
    await tester.pumpAndSettle();
    expect(find.text('修改昵称'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  新名字  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(config.nickname, '新名字');
    expect(find.text('新名字'), findsOneWidget);
    // Let the dialog's delayed controller cleanup timer expire.
    await tester.pump(const Duration(milliseconds: 700));
  });
}
