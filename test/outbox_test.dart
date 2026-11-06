import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/outbox.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/core/transfer_client.dart';
import 'package:lanchat/models/message.dart';
import 'package:lanchat/models/peer.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';
import 'package:lanchat/state/transfers_model.dart';

class FakeSession implements OutboundSession {
  final bool ackAll;
  final bool refuseAll;
  final bool failOnAcks;
  Object? failOnSendAt; // String text that should make sendText throw
  final List<String> sentTexts = [];

  FakeSession({
    this.ackAll = true,
    this.refuseAll = false,
    this.failOnAcks = false,
  });

  @override
  Future<void> sendText(
      {required String msgId, required String text, required int tsMs}) async {
    if (text == failOnSendAt) throw const SocketException('send failed');
    sentTexts.add(text);
  }

  @override
  Future<void> sendFile(
      {required String msgId,
      required String path,
      required int tsMs,
      required void Function(double) onProgress}) async {
    onProgress(1);
  }

  @override
  Future<Map<String, SendReport>> collectAcks(Set<String> msgIds) async {
    if (failOnAcks) throw const SocketException('connection lost');
    return {
      for (final id in msgIds)
        id: SendReport(id, !refuseAll, reason: refuseAll ? 'declined' : null)
    };
  }

  @override
  Future<void> close() async {}
}

class Fixture {
  final AppStore store;
  final PeersModel peers;
  final ChatsModel chats;
  final Outbox outbox;
  Fixture(this.store, this.peers, this.chats, this.outbox);

  static Future<Fixture> create({
    bool peerOnline = true,
    FakeSession Function()? sessionFactory,
    bool connectFails = false,
  }) async {
    final dir = await Directory.systemTemp.createTemp('lanchat_test');
    final store = await AppStore.open(dir);
    final peers = PeersModel(store);
    final chats = ChatsModel(store);
    await chats.load();
    final transfers = TransfersModel();
    final outbox = Outbox(
      store: store,
      peers: peers,
      chats: chats,
      transfers: transfers,
      opener: (Peer peer) async {
        if (connectFails) return null;
        return sessionFactory?.call() ??
            FakeSession();
      },
    );
    chats.attachPending(outbox);
    if (peerOnline) {
      peers.upsertFromAnnounce(
          id: 'peerA', name: 'A', platform: 'windows', port: 1, address: '1.2.3.4');
    }
    return Fixture(store, peers, chats, outbox);
  }

  Future<void> drain(String peerId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (outbox.viewFor(peerId).isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    // give in-flight flush its finally-block time
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test('texts are queued in order and delivered on flush', () async {
    final f = await Fixture.create();
    await f.outbox.sendText('peerA', '1');
    await f.outbox.sendText('peerA', '2');
    await f.drain('peerA');

    expect(f.outbox.viewFor('peerA'), isEmpty);
    final hist = f.chats.historyFor('peerA');
    expect(hist.length, 2);
    expect(hist.every((m) => m.state == SendState.delivered), isTrue);
    expect(f.store.outboxFile('peerA').existsSync(), isFalse);
  });

  test('queue survives reload from disk while pending', () async {
    // connect fails so the message stays queued on disk
    var f = await Fixture.create(connectFails: true);
    await f.outbox.sendText('peerA', 'offline msg');
    await Future.delayed(const Duration(milliseconds: 50));

    // reopen from same dir — pending item must come back
    final peers2 = PeersModel(f.store);
    final chats2 = ChatsModel(f.store);
    await chats2.load();
    f = Fixture(f.store, peers2, chats2,
        Outbox(store: f.store, peers: peers2, chats: chats2, transfers: TransfersModel(), opener: (p) async => null));
    expect(f.outbox.viewFor('peerA').length, 1);
    expect(f.outbox.viewFor('peerA').first.text, 'offline msg');
  });

  test('declined file is refused and blob cleaned up', () async {
    final f = await Fixture.create(
        sessionFactory: () => FakeSession(refuseAll: true));
    final src =
        File('${f.store.base.path}${Platform.pathSeparator}hello.txt')
          ..writeAsStringSync('hi');
    await f.outbox.sendFile('peerA', src.path);
    await f.drain('peerA');

    expect(f.outbox.viewFor('peerA'), isEmpty);
    final hist = f.chats.historyFor('peerA');
    expect(hist.length, 1);
    expect(hist.first.state, SendState.refused);
    expect(hist.first.kind, MsgKind.file);
    expect(f.store.outboxFilesDir.listSync(), isEmpty);
    expect(f.store.outboxFile('peerA').existsSync(), isFalse);
  });

  test('connection failure keeps items pending', () async {
    final f = await Fixture.create(connectFails: true);
    await f.outbox.sendText('peerA', 'queued');
    await f.drain('peerA');
    expect(f.outbox.viewFor('peerA').length, 1);
    expect(f.outbox.viewFor('peerA').first.state, SendState.pending);
    expect(f.store.outboxFile('peerA').existsSync(), isTrue);
  });

  test('ack loss keeps items pending (resend-safe)', () async {
    final f = await Fixture.create(
        sessionFactory: () => FakeSession(failOnAcks: true));
    await f.outbox.sendText('peerA', 'will-not-ack');
    await f.drain('peerA');
    expect(f.outbox.viewFor('peerA').length, 1);
    expect(f.outbox.viewFor('peerA').first.state, SendState.pending);
  });

  test('file delivers, records source path, blob removed', () async {
    final f = await Fixture.create();
    final src =
        File('${f.store.base.path}${Platform.pathSeparator}code.dart')
          ..writeAsStringSync('void main() {}');
    await f.outbox.sendFile('peerA', src.path);
    await f.drain('peerA');

    final hist = f.chats.historyFor('peerA');
    expect(hist.length, 1);
    expect(hist.first.state, SendState.delivered);
    expect(hist.first.fileName, 'code.dart');
    expect(hist.first.filePath, src.path);
    expect(f.store.outboxFilesDir.listSync(), isEmpty);
  });
}
