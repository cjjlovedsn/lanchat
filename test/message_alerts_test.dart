import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/core/message_alerts.dart';
import 'package:lanchat/core/message_text.dart';
import 'package:lanchat/core/store.dart';
import 'package:lanchat/models/message.dart';
import 'package:lanchat/state/chats_model.dart';
import 'package:lanchat/state/peers_model.dart';

class _UnpromptedDarwinPlugin implements FlutterLocalNotificationsPlugin {
  DidReceiveNotificationResponseCallback? onClick;
  @override
  Future<bool?> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    onClick = onDidReceiveNotificationResponse;
    return false;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications implements MessageNotificationPort {
  final shown = <String>[];
  final dismissed = <String>[];
  late void Function(String) tap;
  bool permission = true;
  bool fail = false;
  String? launchPeer;
  Completer<void>? delivery;
  int clears = 0;
  @override
  Future<String?> initialize(void Function(String) onTap) async {
    tap = onTap;
    return launchPeer;
  }

  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<void> show(String peerId, String title, String body) async {
    if (fail) throw StateError('notifications unavailable');
    await delivery?.future;
    shown.add('$peerId:$title:$body');
  }

  @override
  Future<void> dismiss(String peerId) async {
    dismissed.add(peerId);
  }

  @override
  Future<void> dismissAll() async {
    clears++;
  }
}

class _Tray implements TrayAttentionPort {
  bool flashing = false;
  int count = 0;
  @override
  Future<void> setFlashing(bool enabled) async {
    flashing = enabled;
  }

  @override
  Future<void> setUnreadCount(int count) async {
    this.count = count;
  }

  @override
  void dispose() {}
}

ChatMessage message(String id, {String? text}) => ChatMessage(
  id: id,
  outgoing: false,
  kind: MsgKind.text,
  ts: DateTime.now(),
  state: SendState.received,
  text: text ?? id,
);

void main() {
  late Directory dir;
  late AppStore store;
  late Config config;
  late ChatsModel chats;
  late PeersModel peers;
  late _Notifications notifications;
  late _Tray tray;
  late MessageAlerts alerts;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lanchat_alerts_');
    store = await AppStore.open(dir);
    config = await Config.load(store.configFile);
    chats = ChatsModel(store);
    peers = PeersModel(store);
    for (final id in ['a', 'b']) {
      peers.upsertFromAnnounce(
        id: id,
        name: 'Device $id',
        platform: 'windows',
        port: 1,
        address: '127.0.0.1',
      );
    }
    notifications = _Notifications();
    tray = _Tray();
    alerts = MessageAlerts(
      chats: chats,
      peers: peers,
      config: config,
      notifications: notifications,
      tray: tray,
    );
    await alerts.initialize();
  });
  tearDown(() async {
    alerts.dispose();
    chats.dispose();
    peers.dispose();
    config.dispose();
    await Future<void>.delayed(Duration.zero);
    dir.deleteSync(recursive: true);
  });

  test(
    'Darwin initialization without a permission request can still route clicks',
    () async {
      final native = _UnpromptedDarwinPlugin();
      final backend = SystemMessageNotifications(
        plugin: native,
        platform: 'macos',
      );
      final clicked = <String>[];
      expect(await backend.initialize(clicked.add), isNull);
      native.onClick!(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: 'b',
        ),
      );
      expect(clicked, ['b']);
    },
  );

  test(
    'hidden selected conversation remains unread and duplicate packets do not notify twice',
    () async {
      chats.openChat('a');
      chats.setForeground(false);
      chats.onIncoming('a', message('one'));
      chats.onIncoming('a', message('one'));
      await Future<void>.delayed(Duration.zero);
      expect(chats.unread['a'], 1);
      expect(notifications.shown, hasLength(1));
      expect(tray.flashing, true);
      expect(tray.count, 1);
      expect(alerts.latestUnreadPeer, 'a');
    },
  );

  test(
    'viewed chat and outgoing ACKs do not alert; another chat gets an in-app alert',
    () async {
      final inline = <String>[];
      alerts.onInAppAlert = (peer, _, _) => inline.add(peer);
      chats.openChat('a');
      chats.onIncoming('a', message('read'));
      chats.recordAck('b', message('outgoing-ack'));
      expect(chats.totalUnread, 0);
      expect(tray.flashing, false);
      chats.onIncoming('b', message('other'));
      await Future<void>.delayed(Duration.zero);
      expect(inline, ['b']);
      expect(notifications.shown, isEmpty);
      expect(chats.unread['b'], 1);
      expect(tray.flashing, true);
    },
  );

  test(
    'click routing selects its peer before focus and leaves other conversations unread',
    () async {
      chats.openChat('a');
      chats.setForeground(false);
      chats.onIncoming('a', message('a1'));
      chats.onIncoming('b', message('b1'));
      expect(alerts.latestUnreadPeer, 'b');
      alerts.onOpenChat = (id) {
        chats.openChat(id);
        chats.setForeground(true);
      };
      notifications.tap('b');
      await Future<void>.delayed(Duration.zero);
      expect(chats.activePeerId, 'b');
      expect(chats.unread['a'], 1);
      expect(chats.unread['b'], 0);
      expect(alerts.latestUnreadPeer, 'a');
      expect(notifications.dismissed, contains('b'));
      chats.openChat('a');
      expect(tray.flashing, false);
      expect(tray.count, 0);
    },
  );

  test('launch callback waits for navigation and is consumed once', () {
    notifications.tap('b');
    final opened = <String>[];
    alerts.onOpenChat = opened.add;
    alerts.consumeLaunchTap();
    alerts.consumeLaunchTap();
    expect(opened, ['b']);
  });

  test('removed devices do not leave an unclickable flashing badge', () {
    chats.setForeground(false);
    chats.onIncoming('a', message('ghost'));
    peers.removePeer('a');
    expect(alerts.latestUnreadPeer, isNull);
    expect(tray.count, 0);
    expect(tray.flashing, false);
  });

  test(
    'notification and flashing preferences are independent and survive reload',
    () async {
      await config.update(notifyNewMessages: false);
      chats.setForeground(false);
      chats.onIncoming('a', message('silent'));
      await Future<void>.delayed(Duration.zero);
      expect(notifications.shown, isEmpty);
      expect(tray.flashing, true);
      await config.update(flashTrayOnMessage: false);
      expect(tray.flashing, false);
      expect(tray.count, 1);
      final loaded = await Config.load(store.configFile);
      expect(loaded.notifyNewMessages, false);
      expect(loaded.flashTrayOnMessage, false);
      await config.update(flashTrayOnMessage: true);
      expect(tray.flashing, true);
    },
  );

  test(
    'notification failure cannot break incoming chat or tray attention',
    () async {
      notifications.fail = true;
      notifications.permission = false;
      await alerts.requestPermission();
      expect(alerts.permissionGranted, false);
      chats.setForeground(false);
      chats.onIncoming('a', message('saved'));
      await Future<void>.delayed(Duration.zero);
      expect(chats.historyFor('a').single.id, 'saved');
      expect(tray.flashing, true);
      expect(alerts.error, isNotNull);
    },
  );

  test(
    'a notification delivered after the chat was read is dismissed again',
    () async {
      notifications.delivery = Completer<void>();
      chats.setForeground(false);
      chats.onIncoming('a', message('late'));
      chats.openChat('a');
      chats.setForeground(true);
      notifications.delivery!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(notifications.shown, hasLength(1));
      expect(
        notifications.dismissed.where((id) => id == 'a').length,
        greaterThanOrEqualTo(2),
      );
      expect(tray.flashing, false);
    },
  );

  test(
    'returning to the peer list cannot keep an invisible chat marked read',
    () {
      chats.openChat('a');
      chats.closeChat();
      chats.onIncoming('a', message('after-back'));
      expect(chats.unread['a'], 1);
    },
  );

  test(
    'preview distinguishes code and attachments, and preserves Unicode boundaries',
    () {
      expect(
        MessageAlerts.preview(message('code', text: encodeCode('print(1)'))),
        '[代码片段]',
      );
      final long = List.filled(130, '😀').join();
      expect(
        MessageAlerts.preview(message('emoji', text: long)).runes.length,
        120,
      );
      expect(
        MessageAlerts.preview(
          ChatMessage(
            id: 'file',
            outgoing: false,
            kind: MsgKind.file,
            ts: DateTime.now(),
            state: SendState.received,
            fileName: 'movie.mp4',
          ),
        ),
        '[文件] movie.mp4',
      );
    },
  );

  testWidgets(
    'stopping blinking restores the icon even with a delayed native frame',
    (tester) async {
      final frames = <bool>[];
      final firstFrame = Completer<void>();
      final flasher = FlashingTray(
        writeIcon: (dim) async {
          frames.add(dim);
          if (frames.length == 1) await firstFrame.future;
        },
        writeCount: (_) async {},
      );
      final start = flasher.setFlashing(true);
      await tester.pump();
      final stop = flasher.setFlashing(false);
      firstFrame.complete();
      await tester.pump();
      await start;
      await stop;
      expect(frames.last, false);
      final count = frames.length;
      await tester.pump(const Duration(seconds: 3));
      expect(frames.length, count);
      flasher.dispose();
      await tester.pump();
    },
  );
}
