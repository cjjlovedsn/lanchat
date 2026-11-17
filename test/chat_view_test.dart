import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:lanchat/models/message.dart';
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
import 'package:lanchat/ui/app_theme.dart';
import 'package:lanchat/ui/chat_view.dart';
import 'package:lanchat/ui/widgets/bubble.dart';

class _ComposerFixture {
  final Outbox outbox;
  final PeersModel peers;
  _ComposerFixture(this.outbox, this.peers);
  static Future<_ComposerFixture> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    late Directory dir;
    late AppStore store;
    late Config config;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lanchat_composer_');
      store = await AppStore.open(dir);
      config = await Config.load(store.configFile);
    });
    // Paste-triggered file IO can still hold a handle when the fake-async
    // test body ends (Windows locks open files), so deletion is best-effort.
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
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
        child: MaterialApp(
          theme: buildAppTheme(AppAccent.ocean, brightness),
          home: const Scaffold(body: ChatView(peerId: 'peer')),
        ),
      ),
    );
    return _ComposerFixture(outbox, peers);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    peers.dispose();
    outbox.dispose();
  }
}

void main() {
  testWidgets(
    'received and sent images copy bitmap content from their context menu',
    (tester) async {
      final fixture = await _ComposerFixture.mount(tester);
      final context = tester.element(find.byType(ChatView));
      final chats = context.read<ChatsModel>();
      final store = context.read<AppStore>();
      final image = File('${store.base.path}/photo.JPG')
        ..writeAsBytesSync(
          File('assets/brand/lanchat_icon.png').readAsBytesSync(),
        );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const pasteboard = MethodChannel('pasteboard');
      List<int>? copied;
      messenger.setMockMethodCallHandler(pasteboard, (call) async {
        expect(call.method, 'writeImage');
        copied = Platform.isWindows
            ? File(
                (call.arguments as Map)['fileName'] as String,
              ).readAsBytesSync()
            : List<int>.from(call.arguments as List);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(pasteboard, null));
      for (final outgoing in [false, true]) {
        final msg = ChatMessage(
          id: 'image-$outgoing',
          outgoing: outgoing,
          kind: MsgKind.file,
          fileName: 'photo.JPG',
          filePath: image.path,
          fileSize: image.lengthSync(),
          ts: DateTime.now(),
          state: outgoing ? SendState.delivered : SendState.received,
        );
        if (outgoing) {
          chats.recordAck('peer', msg);
        } else {
          chats.onIncoming('peer', msg);
        }
        await tester.pumpAndSettle();
        final bubble = find.byWidgetPredicate(
          (w) => w is MessageBubble && w.msg.id == msg.id,
        );
        final thumbnail = find.descendant(
          of: bubble,
          matching: find.byType(Image),
        );
        await tester.ensureVisible(thumbnail);
        await tester.tap(thumbnail, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        expect(find.text('复制图片'), findsOneWidget);
        copied = null;
        await tester.tap(find.text('复制图片'));
        final timer = Stopwatch()..start();
        while (copied == null) {
          if (timer.elapsed > const Duration(seconds: 5)) {
            throw TestFailure('Image copy did not complete');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(copied!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(find.text('图片已复制'), findsWidgets);
        expect(tester.takeException(), isNull);
      }
      await fixture.close(tester);
    },
  );

  testWidgets(
    'missing images and ordinary attachments have no image copy action; clipboard failures are reported',
    (tester) async {
      final fixture = await _ComposerFixture.mount(tester);
      final context = tester.element(find.byType(ChatView));
      final chats = context.read<ChatsModel>();
      final store = context.read<AppStore>();
      for (final name in ['document.txt', 'missing.png']) {
        final path = '${store.base.path}/$name';
        if (name.endsWith('.txt')) File(path).writeAsStringSync('text');
        chats.onIncoming(
          'peer',
          ChatMessage(
            id: name,
            outgoing: false,
            kind: MsgKind.file,
            fileName: name,
            filePath: path,
            ts: DateTime.now(),
            state: SendState.received,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(name), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        expect(find.text('复制图片'), findsNothing);
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('取消'));
        await tester.pumpAndSettle();
      }
      final photo = File('${store.base.path}/photo.png')
        ..writeAsBytesSync(
          File('assets/brand/lanchat_icon.png').readAsBytesSync(),
        );
      chats.onIncoming(
        'peer',
        ChatMessage(
          id: 'photo',
          outgoing: false,
          kind: MsgKind.file,
          fileName: 'photo.png',
          filePath: photo.path,
          ts: DateTime.now(),
          state: SendState.received,
        ),
      );
      const pasteboard = MethodChannel('pasteboard');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pasteboard,
        (_) async => throw PlatformException(code: 'clipboard-busy'),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(pasteboard, null));
      await tester.pumpAndSettle();
      final image = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is MessageBubble && w.msg.id == 'photo',
        ),
        matching: find.byType(Image),
      );
      await tester.ensureVisible(image);
      await tester.tap(image, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制图片'));
      final timer = Stopwatch()..start();
      while (find.textContaining('复制图片失败').evaluate().isEmpty) {
        if (timer.elapsed > const Duration(seconds: 5)) {
          throw TestFailure('Missing clipboard error');
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'blank row menu clears only current history and pending after confirmation',
    (tester) async {
      final fixture = await _ComposerFixture.mount(tester);
      final context = tester.element(find.byType(ChatView));
      final chats = context.read<ChatsModel>();
      final store = context.read<AppStore>();
      ChatMessage message(String id) => ChatMessage(
        id: id,
        outgoing: false,
        kind: MsgKind.text,
        text: id,
        ts: DateTime.now(),
        state: SendState.received,
      );
      chats.onIncoming('peer', message('existing'));
      chats.onIncoming('other', message('keep-other'));
      await tester.runAsync(() => fixture.outbox.sendText('peer', 'pending'));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(
        find.byKey(const ValueKey('chat-background')),
      );
      // Empty area alongside a bubble must use the conversation menu.
      final blank = Offset(bounds.right - 3, bounds.top + 22);
      await tester.tapAt(blank, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('清空聊天'), findsOneWidget);
      expect(find.text('删除该条'), findsNothing);
      await tester.tap(find.text('清空聊天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(chats.historyFor('peer'), hasLength(1));
      expect(fixture.outbox.viewFor('peer'), hasLength(1));
      // Right clicking the actual bubble still offers message operations.
      await tester.tapAt(
        tester.getTopLeft(find.text('existing')) + const Offset(-8, 5),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('删除该条'), findsOneWidget);
      expect(find.text('清空聊天'), findsNothing);
      await tester.tapAt(blank);
      await tester.pumpAndSettle();
      await tester.tapAt(blank, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空聊天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(chats.historyFor('peer'), isEmpty);
      expect(fixture.outbox.viewFor('peer'), isEmpty);
      expect(chats.historyFor('other').single.id, 'keep-other');
      final restored = ChatsModel(store);
      await tester.runAsync(() => restored.load());
      expect(restored.historyFor('peer'), isEmpty);
      expect(store.outboxFile('peer').existsSync(), isFalse);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'Paste sends copied files, image bytes and preserves plain text',
    (tester) async {
      final fixture = await _ComposerFixture.mount(tester);
      final store = tester.element(find.byType(ChatView)).read<AppStore>();
      final file = File('${store.base.path}/sample.txt')
        ..writeAsStringSync('attachment');
      final imageBytes = File(
        'assets/brand/lanchat_icon.png',
      ).readAsBytesSync();
      // The Windows pasteboard plugin hands the image over as a temp file
      // path that the Dart side reads and deletes; other platforms get bytes.
      final imageFile = File('${store.base.path}/pasted-image.bin')
        ..writeAsBytesSync(imageBytes);
      var mode = 'files';
      const native = MethodChannel('lanchat/clipboard');
      const pasteboard = MethodChannel('pasteboard');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        native,
        (call) async => mode == 'files' ? [file.path] : <String>[],
      );
      messenger.setMockMethodCallHandler(pasteboard, (call) async {
        if (call.method == 'files') {
          return mode == 'files' ? [file.path] : <String>[];
        }
        if (call.method == 'image' && mode == 'image') {
          return Platform.isWindows ? imageFile.path : imageBytes;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': '  pasted\n  code'};
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(pasteboard, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      Future<void> paste() async {
        final field = tester.element(find.byType(EditableText));
        await tester.runAsync(() async {
          final modifier = Theme.of(field).platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft;
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(modifier);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await tester.enterText(find.byType(TextField), 'draft');
      await paste();
      expect(fixture.outbox.viewFor('peer').single.fileName, 'sample.txt');
      expect(fixture.outbox.viewFor('peer').single.kind, MsgKind.file);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'draft',
      );
      mode = 'image';
      await paste();
      final image = fixture.outbox.viewFor('peer').last;
      expect(image.fileName, startsWith('粘贴的图片-'));
      expect(File(image.filePath!).readAsBytesSync(), imageBytes);
      mode = 'text';
      await paste();
      expect(fixture.outbox.viewFor('peer'), hasLength(2));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'draft  pasted\n  code',
      );
      await fixture.close(tester);
    },
  );

  testWidgets('Enter sends exactly once and preserves pasted whitespace', (
    tester,
  ) async {
    final fixture = await _ComposerFixture.mount(tester);
    const raw = '  first line\n    second line\n\n';
    await tester.enterText(find.byType(TextField), raw);
    expect(
      tester.widget<TextField>(find.byType(TextField)).textInputAction,
      TextInputAction.send,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.outbox.viewFor('peer').single.text, raw);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await fixture.close(tester);
  });

  testWidgets('Shift and Ctrl Enter insert newlines without sending code', (
    tester,
  ) async {
    final fixture = await _ComposerFixture.mount(
      tester,
      brightness: Brightness.dark,
    );
    await tester.tap(find.byTooltip('切换为代码消息'));
    await tester.enterText(find.byType(TextField), '  first');
    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
    }
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '  first\n\n');
    expect(fixture.outbox.viewFor('peer'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      decodeCode(fixture.outbox.viewFor('peer').single.text!),
      '  first\n\n',
    );
    await fixture.close(tester);
  });

  testWidgets('Enter does not send an active IME composition', (tester) async {
    final fixture = await _ComposerFixture.mount(tester);
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    await tester.showKeyboard(find.byType(TextField));
    controller.value = const TextEditingValue(
      text: '中文',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.outbox.viewFor('peer'), isEmpty);
    expect(controller.text, contains('中文'));
    controller.value = const TextEditingValue(
      text: '中文',
      selection: TextSelection.collapsed(offset: 2),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.outbox.viewFor('peer').single.text, '中文');
    await fixture.close(tester);
  });
}
