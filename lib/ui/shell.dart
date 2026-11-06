import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants.dart';
import '../state/chats_model.dart';
import 'chat_view.dart';
import 'peer_list.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> with WindowListener, TrayListener {
  String? selectedPeerId;

  @override
  void initState() {
    super.initState();
    if (!K.isDesktop) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    if (K.isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await windowManager.hide(); // stay resident so the outbox can flush
  }

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      _show();
    } else if (menuItem.key == 'exit') {
      windowManager.destroy().then((_) => exit(0));
    }
  }

  void _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _select(String peerId) {
    setState(() => selectedPeerId = peerId);
    context.read<ChatsModel>().openChat(peerId);
  }

  @override
  Widget build(BuildContext context) {
    // phones: single column, list <-> chat with a back button
    final narrow = MediaQuery.of(context).size.width < 640;
    final list = PeerListPanel(
      selectedPeerId: selectedPeerId,
      onSelect: _select,
    );
    final body = narrow
        ? (selectedPeerId == null
            ? list
            : ChatView(
                peerId: selectedPeerId!,
                onBack: () => setState(() => selectedPeerId = null),
              ))
        : Row(
            children: [
              SizedBox(width: 300, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: selectedPeerId == null
                    ? const _EmptyView()
                    : ChatView(peerId: selectedPeerId!),
              ),
            ],
          );
    return Scaffold(body: SafeArea(child: body));
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text('从左侧选择一个设备开始聊天',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline, fontSize: 14)),
        ],
      ),
    );
  }
}
