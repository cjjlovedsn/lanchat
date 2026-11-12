import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/util.dart';
import '../models/peer.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import '../core/config.dart';
import 'widgets/settings_dialog.dart';

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
    final list = peers.sorted;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Row(
            children: [
              Icon(
                Icons.lan_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 8),
              const Text(
                'LanChat',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 20),
                tooltip: '设置',
                onPressed: () => showSettingsDialog(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '暂未发现局域网设备\n\n确认对方设备也运行着 LanChat',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) =>
                      _tile(context, peers, chats, list[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: _colorFor(cfg.deviceId),
                child: Text(
                  cfg.nickname.isEmpty ? '?' : cfg.nickname.characters.first,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
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
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      '本机',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tile(
    BuildContext context,
    PeersModel peers,
    ChatsModel chats,
    Peer p,
  ) {
    final online = peers.isOnline(p.id);
    final unread = chats.unread[p.id] ?? 0;
    return GestureDetector(
      onSecondaryTapUp: (d) => _confirmRemovePeer(context, peers, p),
      child: ListTile(
        onLongPress: () => _confirmRemovePeer(context, peers, p),
        dense: true,
        selected: p.id == selectedPeerId,
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: _colorFor(p.id),
              child: Text(
                p.name.isEmpty ? '?' : p.name.characters.first,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: online
                      ? const Color(0xFF44BD5C)
                      : Colors.grey.shade400,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              p.platform == 'android'
                  ? Icons.phone_android
                  : p.platform == 'macos'
                  ? Icons.laptop_mac
                  : Icons.desktop_windows,
              size: 13,
              color: Colors.grey.shade500,
            ),
          ],
        ),
        subtitle: Text(
          online ? '在线' : '离线 · ${formatLastSeen(p.lastSeen)}',
          style: TextStyle(
            fontSize: 11.5,
            color: online ? const Color(0xFF44BD5C) : Colors.grey,
          ),
        ),
        trailing: unread > 0
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFE05252),
                  borderRadius: BorderRadius.circular(10),
                ),
                constraints: const BoxConstraints(minWidth: 18),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              )
            : null,
        onTap: () => onSelect(p.id),
      ),
    );
  }
}
