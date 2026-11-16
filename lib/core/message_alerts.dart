import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/message.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import 'config.dart';
import 'constants.dart';
import 'message_text.dart';

abstract class MessageNotificationPort {
  Future<String?> initialize(void Function(String peerId) onTap);
  Future<bool> requestPermission();
  Future<void> show(String peerId, String title, String body);
  Future<void> dismiss(String peerId);
  Future<void> dismissAll();
}

class SystemMessageNotifications implements MessageNotificationPort {
  final FlutterLocalNotificationsPlugin plugin;
  final String platform;
  bool _initialized = false;
  int _id(String peer) {
    final bytes = sha256.convert(utf8.encode(peer)).bytes;
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        0x7fffffff;
  }

  SystemMessageNotifications({
    FlutterLocalNotificationsPlugin? plugin,
    String? platform,
  }) : plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       platform = platform ?? Platform.operatingSystem;

  @override
  Future<String?> initialize(void Function(String) onTap) async {
    final initialized = await plugin.initialize(
      InitializationSettings(
        android: const AndroidInitializationSettings('ic_notification'),
        macOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        windows: WindowsInitializationSettings(
          appName: K.appName,
          appUserModelId: 'local.lanchat.LanChat',
          guid: '5d2750ec-e7ad-4f5a-a834-760821ac9bc3',
          iconPath: p.join(
            p.dirname(Platform.resolvedExecutable),
            'data',
            'flutter_assets',
            'assets',
            'tray_icon.ico',
          ),
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final peer = response.payload;
        if (peer != null && peer.isNotEmpty) onTap(peer);
      },
    );
    // Darwin returns the permission result, including false when all initial
    // permission requests were disabled. Native initialization still succeeded.
    if (initialized == false && platform != 'macos') {
      throw StateError('Cannot initialize native notifications');
    }
    _initialized = true;
    final launch = await plugin.getNotificationAppLaunchDetails();
    return launch?.didNotificationLaunchApp == true
        ? launch?.notificationResponse?.payload
        : null;
  }

  @override
  Future<bool> requestPermission() async {
    if (!_initialized) {
      throw StateError('Native notifications are not initialized');
    }
    if (Platform.isMacOS) {
      return await plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (Platform.isAndroid) {
      return await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    return true;
  }

  @override
  Future<void> show(String peerId, String title, String body) async {
    final id = _id(peerId);
    await plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: const AndroidNotificationDetails(
          'lanchat_messages',
          '聊天消息',
          channelDescription: '局域网设备发来的新消息',
          importance: Importance.high,
          priority: Priority.high,
          onlyAlertOnce: false,
        ),
        macOS: DarwinNotificationDetails(
          threadIdentifier: peerId,
          presentAlert: true,
          presentBanner: true,
          presentList: true,
        ),
        windows: const WindowsNotificationDetails(),
      ),
      payload: peerId,
    );
  }

  @override
  Future<void> dismiss(String peerId) async {
    await plugin.cancel(_id(peerId));
  }

  @override
  Future<void> dismissAll() => plugin.cancelAll();
}

abstract class TrayAttentionPort {
  Future<void> setFlashing(bool enabled);
  Future<void> setUnreadCount(int count);
  void dispose();
}

/// Keep the status item's hit area in place while alternating image alpha.
/// Serialize native writes so a late blank frame cannot overwrite Stop.
class FlashingTray implements TrayAttentionPort {
  final Future<void> Function(bool dim) writeIcon;
  final Future<void> Function(int count) writeCount;
  final Duration interval;
  Timer? _timer;
  Future<void> _writes = Future.value();
  Future<void> _countWrites = Future.value();
  int _count = 0;
  bool _dim = false;
  bool _disposed = false;

  FlashingTray({
    Future<void> Function(bool)? writeIcon,
    Future<void> Function(int)? writeCount,
    this.interval = const Duration(milliseconds: 800),
  }) : writeIcon = writeIcon ?? _nativeIcon,
       writeCount = writeCount ?? _nativeCount;

  static Future<void> _nativeIcon(bool dim) async {
    final icon = Platform.isMacOS
        ? (dim ? 'assets/tray_icon_dim.png' : 'assets/tray_icon_template.png')
        : (dim ? 'assets/tray_icon_dim.ico' : 'assets/tray_icon.ico');
    await trayManager.setIcon(icon, isTemplate: Platform.isMacOS);
  }

  static Future<void> _nativeCount(int count) async {
    await trayManager.setToolTip(
      count == 0 ? K.appName : '${K.appName} · $count 条未读消息',
    );
    if (Platform.isMacOS) {
      await windowManager.setBadgeLabel(count == 0 ? '' : '$count');
    }
  }

  Future<void> _render() => _writes = _writes.then((_) async {
    try {
      await writeIcon(_dim);
    } catch (_) {
      /* The next normal frame can retry. */
    }
  });
  @override
  Future<void> setFlashing(bool enabled) async {
    if (_disposed) return;
    if (enabled) {
      if (_timer != null) return;
      _dim = true;
      _timer = Timer.periodic(interval, (_) {
        _dim = !_dim;
        _render();
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _dim = false;
    }
    await _render();
  }

  @override
  Future<void> setUnreadCount(int count) {
    _count = count;
    return _countWrites = _countWrites.then((_) async {
      try {
        await writeCount(_count);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _dim = false;
    _render();
    setUnreadCount(0);
    _disposed = true;
  }
}

class MessageAlerts extends ChangeNotifier {
  final ChatsModel chats;
  final PeersModel peers;
  final Config config;
  final MessageNotificationPort notifications;
  final TrayAttentionPort? tray;
  StreamSubscription<IncomingChat>? _incoming;
  final Map<String, int> _arrival = {};
  final Map<String, int> _previousUnread = {};
  int _sequence = 0;
  int _lastCount = -1;
  bool? _lastFlash;
  bool _disposed = false;
  bool? permissionGranted;
  String? error;
  String? _pendingPeer;
  void Function(String peerId)? onOpenChat;
  void Function(String peerId, String title, String preview)? onInAppAlert;

  MessageAlerts({
    required this.chats,
    required this.peers,
    required this.config,
    required this.notifications,
    this.tray,
  });

  int get unreadCount => chats.unread.entries
      .where((e) => peers.byId(e.key) != null)
      .fold(0, (count, entry) => count + entry.value);
  String? get latestUnreadPeer {
    final ids = chats.unread.keys
        .where((id) => (chats.unread[id] ?? 0) > 0 && peers.byId(id) != null)
        .toList();
    ids.sort((a, b) {
      final order = (_arrival[b] ?? 0).compareTo(_arrival[a] ?? 0);
      if (order != 0) return order;
      DateTime last(String id) =>
          chats.historyFor(id).where((m) => !m.outgoing).lastOrNull?.ts ??
          DateTime(1970);
      return last(b).compareTo(last(a));
    });
    return ids.firstOrNull;
  }

  Future<void> initialize() async {
    _incoming = chats.incoming.listen(_onIncoming);
    chats.addListener(_syncAttention);
    peers.addListener(_syncAttention);
    config.addListener(_onConfig);
    try {
      _pendingPeer = await notifications.initialize(openPeer);
    } catch (_) {
      error = '系统通知暂不可用，未读提示仍然有效';
    }
    _syncAttention();
  }

  void openPeer(String peerId) {
    if (_disposed) return;
    final callback = onOpenChat;
    if (callback == null) {
      _pendingPeer = peerId;
    } else {
      callback(peerId);
    }
  }

  void consumeLaunchTap() {
    final peer = _pendingPeer;
    _pendingPeer = null;
    if (peer != null) openPeer(peer);
  }

  Future<void> requestPermission() async {
    try {
      permissionGranted = await notifications.requestPermission();
      error = permissionGranted == true
          ? null
          : '系统通知未获允许；可在系统设置中开启，应用内提醒和托盘闪烁仍可用';
    } catch (_) {
      permissionGranted = false;
      error = '无法获取通知权限，请检查系统设置';
    }
    if (!_disposed) notifyListeners();
  }

  static String preview(ChatMessage message) {
    if (message.kind == MsgKind.file) {
      return '[文件] ${message.fileName ?? '新文件'}';
    }
    if (decodeCode(message.text ?? '') != null) return '[代码片段]';
    final text = (message.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return String.fromCharCodes(text.runes.take(120));
  }

  void _onIncoming(IncomingChat incoming) {
    _arrival[incoming.peerId] = ++_sequence;
    if (!config.notifyNewMessages ||
        (chats.unread[incoming.peerId] ?? 0) == 0) {
      return;
    }
    final title = peers.byId(incoming.peerId)?.name ?? '局域网设备';
    final text = preview(incoming.message);
    if (chats.isForeground) {
      onInAppAlert?.call(incoming.peerId, title, text);
    } else {
      _show(incoming.peerId, title, text);
    }
  }

  Future<void> _show(String peer, String title, String body) async {
    try {
      await notifications.show(peer, title, body);
    } catch (_) {
      error = '系统消息通知未显示，请检查系统通知设置';
      if (!_disposed) notifyListeners();
    }
    // Reading while native delivery was awaiting must not leave a stale banner.
    if ((chats.unread[peer] ?? 0) == 0) _dismiss(peer);
  }

  Future<void> _dismiss(String peer) async {
    try {
      await notifications.dismiss(peer);
    } catch (_) {}
  }

  void _syncAttention() {
    for (final entry in _previousUnread.entries) {
      if (entry.value > 0 &&
          ((chats.unread[entry.key] ?? 0) == 0 ||
              peers.byId(entry.key) == null)) {
        _dismiss(entry.key);
      }
    }
    _previousUnread
      ..clear()
      ..addAll(chats.unread);
    final count = unreadCount;
    if (count != _lastCount) {
      _lastCount = count;
      tray?.setUnreadCount(count);
    }
    final flash = config.flashTrayOnMessage && count > 0;
    if (flash != _lastFlash) {
      _lastFlash = flash;
      tray?.setFlashing(flash);
    }
  }

  void _onConfig() {
    _syncAttention();
    if (!config.notifyNewMessages) _dismissAll();
  }

  Future<void> _dismissAll() async {
    try {
      await notifications.dismissAll();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _incoming?.cancel();
    chats.removeListener(_syncAttention);
    peers.removeListener(_syncAttention);
    config.removeListener(_onConfig);
    tray?.dispose();
    super.dispose();
  }
}
