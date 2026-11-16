import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/config.dart';
import 'core/startup.dart';
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
import 'ui/app_theme.dart';
import 'ui/widgets/video_poster.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  VideoPosters.enabled = true;
  if (K.isDesktop) {
    await windowManager.ensureInitialized();
  }

  final startup = StartupService();
  await startup.initialize();
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

  final discovery = Discovery(
    cfg: config,
    peers: peers,
    onDiagnostic: (line) {
      try {
        final log = File('${store.base.path}/network.log');
        if (log.existsSync() && log.lengthSync() > 128 * 1024) {
          log.writeAsStringSync('');
        }
        log.writeAsStringSync('$line\n', mode: FileMode.append);
      } catch (_) {}
    },
  );
  await discovery.start();
  outbox.startRetry();

  // Android: coming back from background/screen-off, re-join the multicast
  // group (membership is often dropped) and announce immediately.
  AppLifecycleListener(
    onStateChange: (s) {
      if (s == AppLifecycleState.resumed) {
        discovery.rejoinMulticast();
      }
    },
  );

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

  if (K.isDesktop) {
    try {
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray_icon.ico'
            : Platform.isMacOS
            ? 'assets/tray_icon_template.png'
            : 'assets/tray_icon.png',
        isTemplate: Platform.isMacOS,
      );
      await trayManager.setToolTip(K.appName);
    } catch (_) {}
  }

  runApp(
    LanChatApp(
      store: store,
      config: config,
      peers: peers,
      chats: chats,
      transfers: transfers,
      outbox: outbox,
      discovery: discovery,
      startup: startup,
    ),
  );
}

class LanChatApp extends StatelessWidget {
  final AppStore store;
  final Config config;
  final PeersModel peers;
  final ChatsModel chats;
  final TransfersModel transfers;
  final Outbox outbox;
  final Discovery discovery;
  final StartupService startup;

  const LanChatApp({
    super.key,
    required this.store,
    required this.config,
    required this.peers,
    required this.chats,
    required this.transfers,
    required this.outbox,
    required this.discovery,
    required this.startup,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppStore>.value(value: store),
        ChangeNotifierProvider<StartupService>.value(value: startup),
        ChangeNotifierProvider<Discovery>.value(value: discovery),
        ChangeNotifierProvider<Config>.value(value: config),
        ChangeNotifierProvider<PeersModel>.value(value: peers),
        ChangeNotifierProvider<ChatsModel>.value(value: chats),
        ChangeNotifierProvider<TransfersModel>.value(value: transfers),
        ChangeNotifierProvider<Outbox>.value(value: outbox),
      ],
      child: Consumer<Config>(
        builder: (context, settings, _) => MaterialApp(
          title: K.appName,
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(settings.accent, Brightness.light),
          darkTheme: buildAppTheme(settings.accent, Brightness.dark),
          themeMode: settings.appearance.mode,
          home: const ShellPage(),
        ),
      ),
    );
  }
}
