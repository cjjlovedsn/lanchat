import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants.dart';
import '../core/startup.dart';
import '../state/chats_model.dart';
import 'chat_view.dart';
import 'peer_list.dart';
import 'app_theme.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage>
    with WindowListener, TrayListener {
  String? selectedPeerId;
  StartupService? _startup;
  String? _lastStartupError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!K.isDesktop || _startup != null) return;
    _startup = context.read<StartupService>();
    _startup!.addListener(_startupChanged);
    _startupChanged();
  }

  void _startupChanged() {
    _updateTrayMenu();
    final error = _startup?.error;
    if (error != null && error != _lastStartupError) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error)));
        }
      });
    }
    _lastStartupError = error;
  }

  Future<void> _updateTrayMenu() async {
    final startup = _startup;
    if (startup == null) return;
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示主界面'),
            MenuItem.checkbox(
              key: 'startup',
              label: '开机启动',
              checked: startup.enabled,
              disabled: startup.busy,
            ),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出'),
          ],
        ),
      );
    } catch (_) {}
  }

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
    _startup?.removeListener(_startupChanged);
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
  void onTrayIconRightMouseDown() async {
    await _startup?.refresh();
    await _updateTrayMenu();
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      _show();
    } else if (menuItem.key == 'startup') {
      final startup = _startup;
      if (startup != null) startup.setEnabled(!startup.enabled);
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
              SizedBox(width: 308, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: selectedPeerId == null
                    ? const _EmptyView()
                    : ChatView(peerId: selectedPeerId!),
              ),
            ],
          );
    final palette = ChatPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(narrow ? 0 : 16),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: palette.canvas,
              borderRadius: BorderRadius.circular(narrow ? 0 : 20),
              border: narrow
                  ? null
                  : Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: .7),
                    ),
              boxShadow: narrow
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .035),
                        blurRadius: 32,
                        offset: const Offset(0, 10),
                      ),
                    ],
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: .09),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.devices_rounded,
                    size: 32,
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            const Text(
              '随时连接你的设备',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '选择左侧设备，发送文件、链接或代码。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                _feature(context, Icons.folder_open_outlined, '文件直传'),
                _feature(context, Icons.code_rounded, '代码片段'),
                _feature(context, Icons.schedule_rounded, '离线待送'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _feature(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
