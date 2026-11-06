import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/config.dart';
import 'core/constants.dart';
import 'core/discovery.dart';
import 'core/outbox.dart';
import 'core/store.dart';
import 'core/transfer_client.dart';
import 'core/transfer_server.dart';
import 'state/chats_model.dart';
import 'state/peers_model.dart';
import 'state/transfers_model.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (K.isDesktop) {
    await windowManager.ensureInitialized();
  }

  final store = await AppStore.create();
  final config = await Config.load(store.configFile);
  final peers = PeersModel(store);
  await peers.start();
  final chats = ChatsModel(store);
  await chats.load();
  final transfers = TransfersModel();
  final outbox = Outbox(
    store: store,
    peers: peers,
    chats: chats,
    transfers: transfers,
    opener: (peer) => TcpOutboundSession.connect(peer, config),
  );
  chats.attachPending(outbox);
  peers.onPeerOnline = outbox.flushPeer;

  final server = TransferServer(
    cfg: config,
    store: store,
    peers: peers,
    chats: chats,
    transfers: transfers,
  );
  await server.start();

  final discovery = Discovery(cfg: config, peers: peers);
  await discovery.start();
  outbox.startRetry();

  // Android: coming back from background/screen-off, re-join the multicast
  // group (membership is often dropped) and announce immediately.
  AppLifecycleListener(onStateChange: (s) {
    if (s == AppLifecycleState.resumed) {
      discovery.announceNow();
      discovery.rejoinMulticast();
    }
  });

  if (K.isDesktop) {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1020, 680),
        minimumSize: Size(860, 560),
        title: K.appName,
        center: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(LanChatApp(
    store: store,
    config: config,
    peers: peers,
    chats: chats,
    transfers: transfers,
    outbox: outbox,
  ));

  if (!K.isDesktop) return;
  try {
    await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png');
    final menu = Menu(items: [
      MenuItem(key: 'show', label: '显示主界面'),
      MenuItem(key: 'exit', label: '退出'),
    ]);
    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip(K.appName);
  } catch (_) {}
}

class LanChatApp extends StatelessWidget {
  final AppStore store;
  final Config config;
  final PeersModel peers;
  final ChatsModel chats;
  final TransfersModel transfers;
  final Outbox outbox;

  const LanChatApp({
    super.key,
    required this.store,
    required this.config,
    required this.peers,
    required this.chats,
    required this.transfers,
    required this.outbox,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppStore>.value(value: store),
        ChangeNotifierProvider<Config>.value(value: config),
        ChangeNotifierProvider<PeersModel>.value(value: peers),
        ChangeNotifierProvider<ChatsModel>.value(value: chats),
        ChangeNotifierProvider<TransfersModel>.value(value: transfers),
        ChangeNotifierProvider<Outbox>.value(value: outbox),
      ],
      child: MaterialApp(
        title: K.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF4A6BEB),
        ),
        home: const ShellPage(),
      ),
    );
  }
}
