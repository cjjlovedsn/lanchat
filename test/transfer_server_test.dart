import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/protocol.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/core/transfer_server.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';
import 'package:lanchat/state/transfers_model.dart';

void main() {
  test('bad hash is rejected; lost ack resend creates only one file', () async {
    final dir = await Directory.systemTemp.createTemp('lanchat_receive_');
    addTearDown(() => dir.delete(recursive: true));
    final store = await AppStore.open(dir);
    final cfg = await Config.load(store.configFile)
      ..tcpPort = 0;
    final chats = ChatsModel(store);
    final server = TransferServer(
      cfg: cfg,
      store: store,
      peers: PeersModel(store),
      chats: chats,
      transfers: TransfersModel(),
    );
    await server.start();
    addTearDown(server.stop);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      cfg.tcpPort,
    );
    final reader = FrameReader(socket);
    addTearDown(() async {
      await reader.close();
      socket.destroy();
    });
    socket.add(FrameWriter.encode({'type': 'hello', 'id': 'sender'}));
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    Future<Map<String, dynamic>> send(String id, String hash) async {
      socket.add(
        FrameWriter.encode({
          'type': 'file',
          'msgId': id,
          'name': 'video.mp4',
          'size': bytes.length,
          'sha256': hash,
        }, bytes),
      );
      await socket.flush();
      return (await reader.readHeader(timeout: const Duration(seconds: 5)))
          .header;
    }

    expect((await send('bad', '0' * 64))['ok'], false);
    expect(store.defaultDownloadsDir.listSync(), isEmpty);
    expect(chats.historyFor('sender'), isEmpty);
    final hash = sha256.convert(bytes).toString();
    expect((await send('good', hash))['ok'], true);
    expect((await send('good', hash))['ok'], true);
    expect(chats.historyFor('sender'), hasLength(1));
    final files = store.defaultDownloadsDir
        .listSync()
        .whereType<File>()
        .toList();
    expect(files, hasLength(1));
    expect(await files.single.readAsBytes(), bytes);
  });
}
