import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/message_text.dart';
import 'package:lanchat/core/outbox.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';
import 'package:lanchat/state/transfers_model.dart';
import 'package:lanchat/ui/chat_view.dart';

void main() {
  testWidgets(
    'multiline composer preserves raw code and keyboard sends only once',
    (tester) async {
      late Directory dir;
      late AppStore store;
      late Config config;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('lanchat_composer_');
        store = await AppStore.open(dir);
        config = await Config.load(store.configFile);
      });
      addTearDown(() => dir.deleteSync(recursive: true));
      final peers = PeersModel(store)
        ..upsertFromAnnounce(
          id: 'peer',
          name: 'Desktop',
          platform: 'windows',
          port: 1,
          address: '127.0.0.1',
        );
      final chats = ChatsModel(store);
      final transfers = TransfersModel();
      final outbox = Outbox(
        store: store,
        peers: peers,
        chats: chats,
        transfers: transfers,
        opener: (_) async => null,
      );
      addTearDown(outbox.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppStore>.value(value: store),
            ChangeNotifierProvider<Config>.value(value: config),
            ChangeNotifierProvider<PeersModel>.value(value: peers),
            ChangeNotifierProvider<ChatsModel>.value(value: chats),
            ChangeNotifierProvider<TransfersModel>.value(value: transfers),
            ChangeNotifierProvider<Outbox>.value(value: outbox),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ChatView(peerId: 'peer')),
          ),
        ),
      );
      const raw = '  first line\n    second line\n\n';
      await tester.enterText(find.byType(TextField), raw);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, greaterThan(1));
      expect(field.textInputAction, TextInputAction.newline);
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      expect(outbox.viewFor('peer').single.text, raw);
      await tester.tap(find.byTooltip('切换为代码消息'));
      await tester.enterText(find.byType(TextField), raw);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(outbox.viewFor('peer'), hasLength(2));
      expect(decodeCode(outbox.viewFor('peer').last.text!), raw);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    peers.dispose();
    },
  );
}
