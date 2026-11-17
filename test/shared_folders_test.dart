import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/folder_tree.dart';
import 'package:lanchat/core/message_alerts.dart';
import 'package:lanchat/core/protocol.dart';
import 'package:lanchat/core/shared_folders.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/core/transfer_server.dart';
import 'package:lanchat/models/message.dart';
import 'package:lanchat/models/peer.dart';
import 'package:lanchat/models/shared_folder.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';
import 'package:lanchat/state/transfers_model.dart';

void main() {
  late Directory temp, root, output;
  late AppStore store;
  late Config owner, guest;
  late SharedFolders shares;
  late TransferServer server;
  late FolderGrant grant;
  late Peer peer;
  late SharedFolderClient client;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lanchat-shares-');
    store = await AppStore.open(Directory('${temp.path}/owner'));
    final guestStore = await AppStore.open(Directory('${temp.path}/guest'));
    owner = await Config.load(store.configFile)
      ..tcpPort = 0;
    guest = await Config.load(guestStore.configFile);
    root = await Directory('${temp.path}/shared').create();
    output = await Directory('${temp.path}/output').create();
    await File('${root.path}/hello.txt').writeAsString('Hello 局域网');
    await Directory('${root.path}/子目录').create();
    await File('${root.path}/子目录/empty').writeAsBytes([]);
    shares = SharedFolders(store);
    grant = await shares.add(guest.deviceId, root.path);
    server = TransferServer(
      cfg: owner,
      store: store,
      peers: PeersModel(store),
      chats: ChatsModel(store),
      transfers: TransfersModel(),
      sharedFolders: shares,
    );
    await server.start();
    peer = Peer(
      id: owner.deviceId,
      name: 'Owner',
      platform: 'macos',
      port: owner.tcpPort,
      address: InternetAddress.loopbackIPv4.address,
      lastSeen: DateTime.now(),
    );
    client = SharedFolderClient(
      config: guest,
      peer: peer,
      invite: grant.invite,
    );
  });
  tearDown(() async {
    client.cancel();
    await server.stop();
    shares.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> waitForStagingCleanup() async {
    final clock = Stopwatch()..start();
    while (root.listSync().any((e) => e.path.contains('.lanchat-upload-'))) {
      if (clock.elapsed > const Duration(seconds: 5)) {
        throw TestFailure('Upload staging was not cleaned');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'browse nested directories and copy verified files without overwriting',
    () async {
      final listing = await client.list('');
      expect(listing.writable, isFalse);
      expect(listing.entries.first.directory, isTrue);
      expect(listing.entries.map((e) => e.name), ['子目录', 'hello.txt']);
      final download = await client.download('hello.txt', output);
      expect(await download.readAsString(), 'Hello 局域网');
      final duplicate = await client.download('hello.txt', output);
      expect(duplicate.path, endsWith('hello (1).txt'));
      expect((await client.list('子目录')).entries.single.name, 'empty');
      final empty = await client.download('子目录/empty', output);
      expect(await empty.length(), 0);
      expect(output.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'write permission is enforced on the server and changes take effect immediately',
    () async {
      final source = File('${output.path}/hello.txt')..writeAsStringSync('new');
      await expectLater(
        client.upload('', source),
        throwsA(isA<FormatException>()),
      );
      expect(await File('${root.path}/hello.txt').readAsString(), 'Hello 局域网');
      shares.setWritable(grant.invite.id, true);
      expect((await client.list('')).writable, isTrue);
      expect(await client.upload('', source), 'hello (1).txt');
      expect(await File('${root.path}/hello (1).txt').readAsString(), 'new');
      expect(await client.upload('子目录', source), 'hello.txt');
      shares.setWritable(grant.invite.id, false);
      await expectLater(
        client.upload('', source),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'concurrent uploads with the same name do not overwrite one another',
    () async {
      shares.setWritable(grant.invite.id, true);
      final source = File('${output.path}/hello.txt')..writeAsStringSync('new');
      final names = await Future.wait([
        client.upload('', source),
        client.upload('', source),
      ]);
      expect(names.toSet(), {'hello (1).txt', 'hello (2).txt'});
      expect(await File('${root.path}/hello.txt').readAsString(), 'Hello 局域网');
    },
  );

  test(
    'share state persists; revoked and wrong-recipient capabilities cannot be used',
    () async {
      final restored = SharedFolders(store);
      expect(
        restored.forPeer(guest.deviceId).single.root,
        await root.resolveSymbolicLinks(),
      );
      restored.dispose();
      final wrong = FolderInvite(
        id: grant.invite.id,
        token: 'x' * 64,
        name: 'bad',
      );
      final unauthorized = SharedFolderClient(
        config: guest,
        peer: peer,
        invite: wrong,
      );
      await expectLater(unauthorized.list(''), throwsA(isA<FormatException>()));
      final impersonator = SharedFolderClient(
        config: owner,
        peer: peer,
        invite: grant.invite,
      );
      await expectLater(impersonator.list(''), throwsA(isA<FormatException>()));
      shares.revoke(grant.invite.id);
      await expectLater(client.list(''), throwsA(isA<FormatException>()));
      final restarted = SharedFolders(store);
      expect(restarted.forPeer(guest.deviceId), isEmpty);
      restarted.dispose();
    },
  );

  test(
    'traversal, absolute paths and directory symlinks never escape the shared root',
    () async {
      for (final path in [
        '../owner',
        '/etc',
        '子目录/../../owner',
        r'C:\Windows',
        '子目录/../',
        '.',
      ]) {
        await expectLater(
          client.list(path),
          throwsA(isA<FormatException>()),
          reason: path,
        );
      }
      if (!Platform.isWindows) {
        await Link('${root.path}/outside').create(output.path);
        await Link(
          '${root.path}/secret',
        ).create('${store.base.path}/config.json');
        expect(
          (await client.list('')).entries.map((e) => e.name),
          isNot(contains('outside')),
        );
        await expectLater(
          client.list('outside'),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          client.download('secret', output),
          throwsA(isA<FormatException>()),
        );
        shares.setWritable(grant.invite.id, true);
        final file = File('${output.path}/no.txt')..writeAsStringSync('no');
        await expectLater(
          client.upload('outside', file),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  Future<(Socket, FrameReader)> beginUpload(
    String name,
    String hash,
    int size,
  ) async {
    final socket = await Socket.connect(peer.address, peer.port);
    final reader = FrameReader(socket);
    socket.add(FrameWriter.encode({'type': 'hello', 'id': guest.deviceId}));
    socket.add(
      FrameWriter.encode({
        'type': 'shared-folder',
        'action': 'put',
        'id': grant.invite.id,
        'token': grant.invite.token,
        'path': '',
        'name': name,
        'sha256': hash,
        'size': size,
      }),
    );
    await socket.flush();
    return (socket, reader);
  }

  test('corrupt upload is rejected and staging is removed', () async {
    shares.setWritable(grant.invite.id, true);
    final (socket, reader) = await beginUpload('bad.txt', '0' * 64, 4);
    expect((await reader.readHeader()).header['type'], 'folder-ready');
    socket.add(
      FrameWriter.encode({
        'type': 'folder-body',
      }, Uint8List.fromList([1, 2, 3, 4])),
    );
    await socket.flush();
    final reply = await reader.readHeader();
    expect(reply.header['ok'], false);
    socket.destroy();
    await reader.close();
    // A subsequent request completes after the previous handler's cleanup.
    expect(
      (await client.list('')).entries.map((e) => e.name),
      isNot(contains('bad.txt')),
    );
    await waitForStagingCleanup();
    expect(
      root.listSync().where((e) => e.path.contains('.lanchat-upload-')),
      isEmpty,
    );
  });

  test(
    'revoking permission during upload prevents commit and removes partial files',
    () async {
      shares.setWritable(grant.invite.id, true);
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final (socket, reader) = await beginUpload(
        'revoked.txt',
        sha256.convert(bytes).toString(),
        4,
      );
      expect((await reader.readHeader()).header['type'], 'folder-ready');
      shares.setWritable(grant.invite.id, false);
      socket.add(FrameWriter.encode({'type': 'folder-body'}, bytes));
      await socket.flush();
      expect((await reader.readHeader()).header['ok'], false);
      socket.destroy();
      await reader.close();
      await waitForStagingCleanup();
      expect(File('${root.path}/revoked.txt').existsSync(), false);
      expect(
        root.listSync().where((e) => e.path.contains('.lanchat-upload-')),
        isEmpty,
      );
    },
  );

  test(
    'interrupted upload removes staging and never publishes a partial file',
    () async {
      shares.setWritable(grant.invite.id, true);
      final (socket, reader) = await beginUpload('partial.txt', '0' * 64, 1000);
      expect((await reader.readHeader()).header['type'], 'folder-ready');
      socket.add(FrameWriter.encodeHeader({'type': 'folder-body'}, 1000));
      socket.add([1, 2, 3]);
      await socket.flush();
      socket.destroy();
      await reader.close();
      // Wait for the receiver to notice EOF and clean up, without a fixed long sleep.
      for (var i = 0; i < 50; i++) {
        if (root
            .listSync()
            .where((e) => e.path.contains('.lanchat-upload-'))
            .isEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        root.listSync().where((e) => e.path.contains('.lanchat-upload-')),
        isEmpty,
      );
      expect(File('${root.path}/partial.txt').existsSync(), false);
    },
  );

  test(
    'download checksum mismatch and cancellation remove local partial files',
    () async {
      for (final cancel in [false, true]) {
        final fixture = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final fixturePeer = Peer(
          id: 'fixture',
          name: 'fixture',
          platform: 'macos',
          port: fixture.port,
          address: '127.0.0.1',
          lastSeen: DateTime.now(),
        );
        final downloader = SharedFolderClient(
          config: guest,
          peer: fixturePeer,
          invite: grant.invite,
        );
        final connection = fixture.first;
        final download = downloader.download(
          'bad.bin',
          output,
          progress: cancel ? (_) => downloader.cancel() : null,
        );
        final completed = expectLater(download, throwsA(anything));
        final socket = await connection;
        final reader = FrameReader(socket);
        await reader.readHeader(); // hello
        await reader.readHeader(); // request
        socket.add(
          FrameWriter.encodeHeader({
            'type': 'folder-result',
            'ok': true,
            'sha256': '0' * 64,
          }, cancel ? 100 : 4),
        );
        socket.add([1, 2, 3, 4]);
        await socket.flush();
        await completed;
        socket.destroy();
        await reader.close();
        await fixture.close();
        expect(output.listSync(), isEmpty);
      }
    },
  );

  test(
    'unsafe upload filenames are rejected before accepting a body',
    () async {
      shares.setWritable(grant.invite.id, true);
      for (final name in [
        '../escape.txt',
        r'C:\escape.txt',
        'sub/file.txt',
        '..',
        '.lanchat-upload-hidden',
      ]) {
        final (socket, reader) = await beginUpload(name, '0' * 64, 4);
        expect((await reader.readHeader()).header['ok'], false);
        socket.destroy();
        await reader.close();
      }
      expect(
        root.listSync().where((e) => e.path.contains('.lanchat-upload-')),
        isEmpty,
      );
    },
  );

  test(
    'recursive upload and copy preserve nested files, empty folders and folder names with dots',
    () async {
      shares.setWritable(grant.invite.id, true);
      final source = await Directory('${output.path}/工程.backup').create();
      await Directory('${source.path}/子目录/空目录').create(recursive: true);
      await File('${source.path}/子目录/empty.txt').writeAsBytes([]);
      final payload = List<int>.generate(200000, (i) => i % 251);
      await File('${source.path}/video.bin').writeAsBytes(payload);
      if (!Platform.isWindows) {
        await Link('${source.path}/outside').create(store.base.path);
        await Link('${source.path}/loop').create(source.path);
      }
      final progress = <double>[];
      final report = await client.uploadDirectory(
        '',
        source,
        progress: progress.add,
      );
      expect(report.path, '工程.backup');
      expect(report.skippedLinks, Platform.isWindows ? 0 : 2);
      expect(Directory('${root.path}/工程.backup/子目录/空目录').existsSync(), true);
      expect(
        await File('${root.path}/工程.backup/video.bin').readAsBytes(),
        payload,
      );
      expect(File('${root.path}/工程.backup/子目录/empty.txt').lengthSync(), 0);
      expect(
        FileSystemEntity.typeSync(
          '${root.path}/工程.backup/loop',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      expect(progress.last, 1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      final duplicate = await client.uploadDirectory('', source);
      expect(duplicate.path, '工程.backup (1)');
      final copies = await Future.wait([
        client.downloadDirectory('工程.backup', output),
        client.downloadDirectory('工程.backup', output),
      ]);
      expect(
        copies.map((r) => r.path.split(Platform.pathSeparator).last).toSet(),
        {'工程.backup (1)', '工程.backup (2)'},
      );
      for (final copy in copies) {
        expect(Directory('${copy.path}/子目录/空目录').existsSync(), true);
        expect(await File('${copy.path}/video.bin').readAsBytes(), payload);
      }
    },
  );

  test(
    'empty root folders transfer in both directions and read-only still blocks folder uploads',
    () async {
      final source = await Directory('${output.path}/empty-folder').create();
      await expectLater(
        client.uploadDirectory('', source),
        throwsA(isA<FormatException>()),
      );
      shares.setWritable(grant.invite.id, true);
      await client.uploadDirectory('', source);
      final result = await client.downloadDirectory('empty-folder', output);
      expect(Directory(result.path).existsSync(), true);
      expect(Directory(result.path).listSync(), isEmpty);
      final rootCopy = await client.downloadDirectory('', output);
      expect(Directory('${rootCopy.path}/empty-folder').existsSync(), true);
      expect(
        File('${rootCopy.path}/hello.txt').readAsStringSync(),
        'Hello 局域网',
      );
    },
  );

  Future<(Socket, FrameReader)> beginTree(int entries, int bytes) async {
    final socket = await Socket.connect(peer.address, peer.port);
    final reader = FrameReader(socket);
    socket.add(FrameWriter.encode({'type': 'hello', 'id': guest.deviceId}));
    socket.add(
      FrameWriter.encode({
        'type': 'shared-folder',
        'action': 'put-tree',
        'id': grant.invite.id,
        'token': grant.invite.token,
        'path': '',
        'name': 'incoming',
        'entries': entries,
        'bytes': bytes,
        'skippedLinks': 0,
      }),
    );
    await socket.flush();
    return (socket, reader);
  }

  test(
    'recursive upload rejects traversal, bad hashes and incomplete manifests atomically',
    () async {
      shares.setWritable(grant.invite.id, true);
      for (final mode in ['traversal', 'checksum', 'manifest']) {
        final (socket, reader) = await beginTree(1, mode == 'checksum' ? 4 : 0);
        expect((await reader.readHeader()).header['type'], 'folder-ready');
        if (mode == 'checksum') {
          socket.add(
            FrameWriter.encode({
              'type': 'tree-file',
              'path': 'bad.bin',
              'size': 4,
              'sha256': '0' * 64,
            }, Uint8List.fromList([1, 2, 3, 4])),
          );
        } else if (mode == 'traversal') {
          socket.add(
            FrameWriter.encode({'type': 'tree-directory', 'path': '../escape'}),
          );
        } else {
          socket.add(
            FrameWriter.encode({
              'type': 'tree-end',
              'entries': 0,
              'bytes': 0,
              'skippedLinks': 0,
            }),
          );
        }
        await socket.flush();
        expect((await reader.readHeader()).header['ok'], false);
        socket.destroy();
        await reader.close();
        await waitForStagingCleanup();
        expect(Directory('${root.path}/incoming').existsSync(), false);
        expect(Directory('${root.path}/escape').existsSync(), false);
      }
    },
  );

  test(
    'disconnecting or revoking a folder transfer leaves no visible half-folder',
    () async {
      for (final revoke in [false, true]) {
        shares.setWritable(grant.invite.id, true);
        final (socket, reader) = await beginTree(2, 4);
        expect((await reader.readHeader()).header['type'], 'folder-ready');
        socket.add(
          FrameWriter.encode({'type': 'tree-directory', 'path': 'empty'}),
        );
        socket.add(
          FrameWriter.encodeHeader({
            'type': 'tree-file',
            'path': 'data',
            'size': 4,
            'sha256': '0' * 64,
          }, 4),
        );
        socket.add([1, 2]);
        await socket.flush();
        expect(Directory('${root.path}/incoming').existsSync(), false);
        if (revoke) {
          shares.setWritable(grant.invite.id, false);
          socket.add([3, 4]);
          await socket.flush();
          expect((await reader.readHeader()).header['ok'], false);
        }
        socket.destroy();
        await reader.close();
        await waitForStagingCleanup();
        expect(Directory('${root.path}/incoming').existsSync(), false);
      }
    },
  );

  test(
    'recursive download rejects corrupt content and cleans up when cancelled',
    () async {
      for (final cancel in [false, true]) {
        final fixture = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final fixturePeer = Peer(
          id: 'fixture',
          name: 'fixture',
          platform: 'macos',
          port: fixture.port,
          address: '127.0.0.1',
          lastSeen: DateTime.now(),
        );
        final downloader = SharedFolderClient(
          config: guest,
          peer: fixturePeer,
          invite: grant.invite,
        );
        final connection = fixture.first;
        final download = downloader.downloadDirectory(
          'folder',
          output,
          progress: cancel ? (_) => downloader.cancel() : null,
        );
        final completed = expectLater(download, throwsA(anything));
        final socket = await connection;
        final reader = FrameReader(socket);
        await reader.readHeader();
        await reader.readHeader();
        final size = cancel ? 100 : 4;
        socket.add(
          FrameWriter.encode({
            'type': 'folder-result',
            'ok': true,
            'entries': 1,
            'bytes': size,
            'skippedLinks': 0,
          }),
        );
        socket.add(
          FrameWriter.encodeHeader({
            'type': 'tree-file',
            'path': 'bad.bin',
            'size': size,
            'sha256': '0' * 64,
          }, size),
        );
        socket.add([1, 2, 3, 4]);
        await socket.flush();
        await completed;
        socket.destroy();
        await reader.close();
        await fixture.close();
        expect(output.listSync(), isEmpty);
      }
    },
  );

  test('recursive manifests enforce depth and entry limits', () async {
    expect(
      () => treeSegments(List.filled(maxTreeDepth + 1, 'nested').join('/')),
      throwsFormatException,
    );
    expect(
      () => TreeSummary.fromJson({'entries': maxTreeEntries + 1, 'bytes': 0}),
      throwsFormatException,
    );
    shares.setWritable(grant.invite.id, true);
    final (socket, reader) = await beginTree(maxTreeEntries + 1, 0);
    expect((await reader.readHeader()).header['ok'], false);
    socket.destroy();
    await reader.close();
    expect(
      root.listSync().where((e) => e.path.contains('.lanchat-upload-')),
      isEmpty,
    );
  });

  test('share invitations hide the capability in notification previews', () {
    final decoded = FolderInvite.parse(grant.invite.encode())!;
    expect(decoded.token, grant.invite.token);
    final msg = ChatMessage(
      id: 'share',
      outgoing: false,
      kind: MsgKind.text,
      ts: DateTime.now(),
      state: SendState.received,
      text: grant.invite.encode(),
    );
    expect(MessageAlerts.preview(msg), '[共享文件夹] shared');
    expect(MessageAlerts.preview(msg), isNot(contains(grant.invite.token)));
  });
}
