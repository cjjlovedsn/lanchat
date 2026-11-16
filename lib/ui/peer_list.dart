import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/util.dart';
import '../core/discovery.dart';
import 'widgets/network_status.dart';
import '../models/peer.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import '../core/config.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/appearance_dialog.dart';
import 'app_theme.dart';

const _avatarColors = [
  Color(0xFF4A6BEB),
  Color(0xFF38A169),
  Color(0xFFD69E2E),
  Color(0xFFB7791F),
  Color(0xFFCB5C5C),
  Color(0xFF805AD5),
  Color(0xFF319795),
  Color(0xFFD53F8C),
];

Color _colorFor(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _avatarColors[h % _avatarColors.length];
}

Future<void> _confirmRemovePeer(
  BuildContext context,
  PeersModel peers,
  Peer p,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('移除「${p.name}」？'),
      content: const Text('仅从列表移除，聊天记录保留；对方再次上线会重新出现。适合清理重装后遗留的重复设备。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('移除'),
        ),
      ],
    ),
  );
  if (ok == true) peers.removePeer(p.id);
}

class PeerListPanel extends StatelessWidget {
  final String? selectedPeerId;
  final ValueChanged<String> onSelect;
  const PeerListPanel({
    super.key,
    required this.selectedPeerId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final peers = context.watch<PeersModel>();
    final chats = context.watch<ChatsModel>();
    final cfg = context.watch<Config>();
    final discovery = context.watch<Discovery?>();
    final scheme = Theme.of(context).colorScheme;
    final list = peers.sorted;
    final online = list.where((p) => peers.isOnline(p.id)).length;
    final compactButton = IconButton.styleFrom(
      minimumSize: const Size(32, 34),
      maximumSize: const Size(34, 34),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
    return ColoredBox(
      color: ChatPalette.of(context).sidebar,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 12, 20),
            child: Row(
              children: [
                Image.asset(
                  'assets/brand/lanchat_badge.png',
                  width: 36,
                  height: 36,
                  filterQuality: FilterQuality.high,
                  excludeFromSemantics: true,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LanChat',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.5,
                        ),
                      ),
                      SizedBox(height: 1),
                      Text(
                        '连接身边的设备',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  style: compactButton,
                  tooltip: '外观与主题',
                  icon: const Icon(Icons.palette_outlined, size: 18),
                  onPressed: () => showAppearanceDialog(context),
                ),
                if (discovery != null)
                  IconButton(
                    style: compactButton,
                    tooltip: '网络诊断',
                    icon: Icon(
                      discovery.ready && discovery.lastError == null
                          ? Icons.wifi_rounded
                          : Icons.wifi_off_rounded,
                      size: 18,
                    ),
                    onPressed: () => showNetworkStatus(context, discovery),
                  ),
                IconButton(
                  style: compactButton,
                  tooltip: '设置',
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  onPressed: () => showSettingsDialog(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 18, 12),
            child: Row(
              children: [
                Text(
                  '我的设备',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$online 在线',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (discovery != null && discovery.lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Material(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  dense: true,
                  title: Text(
                    '自动发现异常，正在重试',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: scheme.onErrorContainer,
                  ),
                  onTap: () => showNetworkStatus(context, discovery),
                ),
              ),
            ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.radar_rounded,
                            size: 38,
                            color: scheme.primary.withValues(alpha: .5),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            '正在寻找附近设备',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '在同一局域网内打开 LanChat\n设备会自动出现在这里',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.7,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: list.length,
                    itemBuilder: (context, i) =>
                        _tile(context, peers, chats, list[i]),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Material(
              color: scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: .65),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _editOwnNickname(context),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(
                      Icons.computer_rounded,
                      size: 18,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cfg.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '本机 · ${_platformName(cfg.platformLabel)}',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.circle, color: scheme.primary, size: 6),
                  ],
                ),
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }

  Future<void> _editOwnNickname(BuildContext context) async {
    final cfg = context.read<Config>();
    final ctrl = TextEditingController(text: cfg.nickname);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            hintText: '显示给局域网内其他人',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true) await cfg.update(nickname: ctrl.text);
    // The dialog's exit animation still references the controller.
    Future.delayed(const Duration(milliseconds: 600), ctrl.dispose);
  }

  Widget _tile(
    BuildContext context,
    PeersModel peers,
    ChatsModel chats,
    Peer peer,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final selected = peer.id == selectedPeerId;
    final online = peers.isOnline(peer.id);
    final unread = chats.unread[peer.id] ?? 0;
    final status = online
        ? const Color(0xFF28AD83)
        : scheme.onSurfaceVariant.withValues(alpha: .45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: .09)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: .18)
                : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () => onSelect(peer.id),
          onLongPress: () => _confirmRemovePeer(context, peers, peer),
          onSecondaryTapUp: (_) => _confirmRemovePeer(context, peers, peer),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _colorFor(peer.id).withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Icon(
                          _platformIcon(peer.platform),
                          color: _colorFor(peer.id),
                          size: 22,
                        ),
                      ),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: status,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: ChatPalette.of(context).sidebar,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        peer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        online
                            ? '${_platformName(peer.platform)} · 在线'
                            : '离线 · ${formatLastSeen(peer.lastSeen)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unread > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: TextStyle(fontSize: 10, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _platformName(String platform) => switch (platform) {
  'android' => 'Android',
  'macos' => 'macOS',
  'windows' => 'Windows',
  _ => '设备',
};

IconData _platformIcon(String platform) => switch (platform) {
  'android' => Icons.phone_android_rounded,
  'macos' => Icons.laptop_mac_rounded,
  'windows' => Icons.desktop_windows_rounded,
  _ => Icons.devices_rounded,
};
