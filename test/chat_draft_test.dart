import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/outbox.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';
import 'package:lanchat/state/transfers_model.dart';
import 'package:lanchat/ui/app_theme.dart';
import 'package:lanchat/ui/chat_view.dart';

void main() {
  testWidgets(
    'switching conversations preserves separate text and code drafts',
    (tester) async {
      late Directory directory;
      late AppStore store;
      late Config config;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('lanchat_drafts_');
        store = await AppStore.open(directory);
        config = await Config.load(store.configFile);
      });
      addTearDown(() => directory.deleteSync(recursive: true));
      final chats = ChatsModel(store);
      final peers = PeersModel(store);
      final transfers = TransfersModel();
      final selected = ValueNotifier('a');
      final outbox = Outbox(
        store: store,
        peers: peers,
        chats: chats,
        transfers: transfers,
        opener: (_) async => null,
      );
      for (final id in ['a', 'b']) {
        peers.upsertFromAnnounce(
          id: id,
          name: id,
          platform: 'windows',
          port: 1,
          address: '127.0.0.1',
        );
      }
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppStore>.value(value: store),
            ChangeNotifierProvider<Config>.value(value: config),
            ChangeNotifierProvider<ChatsModel>.value(value: chats),
            ChangeNotifierProvider<PeersModel>.value(value: peers),
            ChangeNotifierProvider<TransfersModel>.value(value: transfers),
            ChangeNotifierProvider<Outbox>.value(value: outbox),
          ],
          child: MaterialApp(
            theme: buildAppTheme(AppAccent.ocean, Brightness.light),
            home: Scaffold(
              body: ValueListenableBuilder<String>(
                valueListenable: selected,
                builder: (_, id, _) => ChatView(key: ValueKey(id), peerId: id),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('切换为代码消息'));
      await tester.enterText(find.byType(TextField), '  first\n    draft');
      selected.value = 'b';
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.byTooltip('切换为代码消息'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'second draft');
      selected.value = 'a';
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '  first\n    draft',
      );
      expect(find.byTooltip('切换为普通文字'), findsOneWidget);
      selected.value = 'b';
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'second draft',
      );
      expect(outbox.pendingCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      selected.dispose();
      chats.dispose();
      peers.dispose();
      transfers.dispose();
      outbox.dispose();
      config.dispose();
    },
  );
}
