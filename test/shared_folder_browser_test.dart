import 'dart:io';

import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/models/message.dart';
import 'package:lanchat/ui/widgets/bubble.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/shared_folders.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/models/peer.dart';
import 'package:lanchat/models/shared_folder.dart';
import 'package:lanchat/ui/shared_folders_page.dart';

class _Client extends SharedFolderClient {
  bool writable = false;
  final paths = <String>[];
  final uploaded = <String>[];
  final uploadedDirectories = <String>[];
  final downloadedDirectories = <String>[];
  _Client(Config config)
    : super(
        config: config,
        peer: Peer(
          id: 'owner',
          name: 'Owner',
          platform: 'macos',
          port: 0,
          lastSeen: DateTime.now(),
        ),
        invite: const FolderInvite(
          id: 'folder',
          token: 'abcdefghijklmnopqrstuvwxyz0123456789',
          name: '共享资料',
        ),
      );
  @override
  Future<FolderListing> list(String path) async {
    paths.add(path);
    return FolderListing(
      path.isEmpty
          ? const [
              FolderEntry(name: '子目录', directory: true),
              FolderEntry(name: 'hello.txt', directory: false, size: 5),
            ]
          : [],
      writable,
    );
  }

  @override
  Future<String> upload(
    String path,
    File file, {
    void Function(double)? progress,
  }) async {
    uploaded.add(file.path);
    progress?.call(1);
    return 'uploaded';
  }

  @override
  Future<FolderTransferReport> uploadDirectory(
    String path,
    Directory directory, {
    void Function(double)? progress,
  }) async {
    uploadedDirectories.add(directory.path);
    progress?.call(1);
    return const FolderTransferReport('uploaded-folder', 0);
  }

  @override
  Future<FolderTransferReport> downloadDirectory(
    String path,
    Directory destination, {
    void Function(double)? progress,
  }) async {
    downloadedDirectories.add(path);
    final name = path.isEmpty ? invite.name : path.split('/').last;
    final dir = await Directory(
      '${destination.path}/$name/空目录',
    ).create(recursive: true);
    await File('${dir.parent.path}/hello.txt').writeAsString('nested');
    progress?.call(1);
    return FolderTransferReport(dir.parent.path, 0);
  }

  @override
  Future<File> download(
    String path,
    Directory destination, {
    void Function(double)? progress,
  }) async {
    final file = await File(
      '${destination.path}/hello.txt',
    ).writeAsString('hello');
    progress?.call(1);
    return file;
  }
}

// Give real filesystem I/O time to finish while also pumping the widget's
// fake-clock microtasks; neither side can await a future owned by the other.
Future<void> _waitFor(WidgetTester tester, bool Function() complete) async {
  final clock = Stopwatch()..start();
  while (!complete()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      throw TestFailure('Operation did not complete');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppStore store;
  late _Client client;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lanchat-folder-ui-');
    store = await AppStore.open(temp);
    client = _Client(await Config.load(store.configFile));
  });
  tearDown(() async {
    client.cancel();
    await temp.delete(recursive: true);
  });

  testWidgets('folder cards open without rendering the private capability', (
    tester,
  ) async {
    var opened = false;
    final message = ChatMessage(
      id: 'invite',
      outgoing: false,
      kind: MsgKind.text,
      ts: DateTime.now(),
      state: SendState.received,
      text: client.invite.encode(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            msg: message,
            onOpenSharedFolder: () => opened = true,
          ),
        ),
      ),
    );
    expect(find.text('共享资料'), findsOneWidget);
    expect(find.textContaining(client.invite.token), findsNothing);
    await tester.tap(find.text('共享资料'));
    expect(opened, isTrue);
  });

  testWidgets(
    'owner can change write permission and revoke from the shared folder entry',
    (tester) async {
      final shares = SharedFolders(store);
      final chats = ChatsModel(store);
      final grant = await tester.runAsync(() => shares.add('guest', temp.path));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SharedFolders>.value(value: shares),
            ChangeNotifierProvider<ChatsModel>.value(value: chats),
          ],
          child: const MaterialApp(home: SharedFoldersPage(peerId: 'guest')),
        ),
      );
      await tester.pumpAndSettle();
      expect(shares.forPeer('guest').single.writable, isFalse);
      await tester.tap(find.text('允许对方写入文件'));
      await tester.pumpAndSettle();
      expect(shares.forPeer('guest').single.writable, isTrue);
      await tester.tap(find.byTooltip('取消共享'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消共享').last);
      await tester.pumpAndSettle();
      expect(shares.forPeer('guest'), isEmpty);
      expect(grant, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      shares.dispose();
      chats.dispose();
    },
  );

  testWidgets(
    'browser fits phone, enforces read-only UI and navigates folders',
    (tester) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: SharedFolderBrowser(client: client, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('只读'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('粘贴文件'),
                matching: find.byWidgetPredicate((w) => w is OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('子目录'));
      await tester.pumpAndSettle();
      expect(find.text('文件夹为空'), findsOneWidget);
      expect(client.paths.last, '子目录');
      await tester.tap(find.byTooltip('上一级'));
      await tester.pumpAndSettle();
      expect(client.paths.last, '');
      expect(find.text('hello.txt'), findsOneWidget);
    },
  );

  testWidgets(
    'folders can be selected, copied to the file clipboard, pasted and dropped',
    (tester) async {
      client.writable = true;
      final folder = await tester.runAsync(
        () => Directory('${temp.path}/待上传').create(),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      List<String>? copied;
      const native = MethodChannel('lanchat/clipboard');
      const pasteboard = MethodChannel('pasteboard');
      messenger.setMockMethodCallHandler(native, (_) async => [folder!.path]);
      messenger.setMockMethodCallHandler(pasteboard, (call) async {
        if (call.method == 'files') return [folder!.path];
        if (call.method == 'writeFiles') {
          copied = List<String>.from(call.arguments as List);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(pasteboard, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SharedFolderBrowser(client: client, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('上传文件夹'), findsOneWidget);
      // The directory's checkbox selects it; tapping its name still navigates.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.text('复制文件'));
      await _waitFor(tester, () => copied != null);
      await _waitFor(
        tester,
        () =>
            tester
                .widget<OutlinedButton>(
                  find.ancestor(
                    of: find.text('复制文件'),
                    matching: find.byWidgetPredicate(
                      (w) => w is OutlinedButton,
                    ),
                  ),
                )
                .onPressed !=
            null,
      );
      expect(copied, hasLength(1));
      expect(Directory('${copied!.single}/空目录').existsSync(), true);
      expect(File('${copied!.single}/hello.txt').readAsStringSync(), 'nested');
      await tester.tap(find.text('粘贴文件'));
      await _waitFor(tester, () => client.uploadedDirectories.length == 1);
      await tester.pumpAndSettle();
      expect(client.uploadedDirectories.single, folder!.path);
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        DropDoneDetails(
          files: [DropItemDirectory(folder.path, [])],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await _waitFor(tester, () => client.uploadedDirectories.length == 2);
      await tester.pumpAndSettle();
      expect(client.uploadedDirectories.last, folder.path);
      await tester.tap(find.byTooltip('整个当前文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制整个当前文件夹'));
      await _waitFor(tester, () => copied!.single.endsWith('共享资料'));
      await _waitFor(
        tester,
        () =>
            tester
                .widget<OutlinedButton>(
                  find.ancestor(
                    of: find.text('粘贴文件'),
                    matching: find.byWidgetPredicate(
                      (w) => w is OutlinedButton,
                    ),
                  ),
                )
                .onPressed !=
            null,
      );
      expect(client.downloadedDirectories, ['子目录', '']);
      expect(Directory('${copied!.single}/空目录').existsSync(), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pasted files upload only when writable and copying uses actual file clipboard',
    (tester) async {
      client.writable = true;
      final source = File('${temp.path}/source.txt')..writeAsStringSync('test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      List<String>? copied;
      const native = MethodChannel('lanchat/clipboard');
      const pasteboard = MethodChannel('pasteboard');
      messenger.setMockMethodCallHandler(native, (_) async => [source.path]);
      messenger.setMockMethodCallHandler(pasteboard, (call) async {
        if (call.method == 'files') return [source.path];
        if (call.method == 'writeFiles') {
          copied = List<String>.from(call.arguments as List);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(pasteboard, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SharedFolderBrowser(client: client, store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴文件'));
      await _waitFor(tester, () => client.uploaded.isNotEmpty);
      await tester.pumpAndSettle();
      expect(client.uploaded, [source.path]);
      await tester.tap(find.text('hello.txt'));
      await tester.pump();
      await tester.tap(find.text('复制文件'));
      await _waitFor(tester, () => copied != null);
      await tester.pumpAndSettle();
      expect(copied, hasLength(1));
      expect(File(copied!.single).readAsStringSync(), 'hello');
      await _waitFor(
        tester,
        () =>
            tester
                .widget<OutlinedButton>(
                  find.ancestor(
                    of: find.text('复制文件'),
                    matching: find.byWidgetPredicate(
                      (w) => w is OutlinedButton,
                    ),
                  ),
                )
                .onPressed !=
            null,
      );
      expect(find.textContaining('可到访达或资源管理器粘贴'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // Clipboard files remain usable after leaving the browser.
      expect(File(copied!.single).existsSync(), isTrue);
    },
  );
}
