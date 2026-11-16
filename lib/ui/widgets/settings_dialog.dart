import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/constants.dart';
import '../../core/startup.dart';
import '../../core/app_updates.dart';
import 'update_dialog.dart';
import '../../core/storage_perm.dart';
import '../../core/store.dart';
import '../app_theme.dart';
import 'appearance_dialog.dart';

Future<void> showSettingsDialog(BuildContext context) async {
  if (K.isDesktop) await context.read<StartupService>().refresh();
  if (!context.mounted) return;
  final cfg = context.read<Config>();
  final store = context.read<AppStore>();
  final nickCtrl = TextEditingController(text: cfg.nickname);
  String? downloadDir = cfg.downloadDir;
  bool autoAccept = cfg.autoAccept;
  bool storageGranted = true;
  if (Platform.isAndroid) {
    storageGranted = await StoragePerm.isGranted();
  }
  if (!context.mounted) return;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('设置'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Consumer<Config>(
                  builder: (context, config, _) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text(
                      '外观与主题',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${config.accent.label} · ${config.appearance.label}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showAppearanceDialog(context),
                  ),
                ),
                if (K.isDesktop)
                  Consumer<StartupService>(
                    builder: (context, startup, _) => SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('开机启动', style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        startup.error ?? '登录电脑后自动打开 LanChat',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: startup.enabled,
                      onChanged: startup.busy ? null : startup.setEnabled,
                    ),
                  ),
                Consumer<AppUpdates>(
                  builder: (context, updates, _) => Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.system_update_alt_rounded),
                        title: const Text('检查更新'),
                        subtitle: Text('当前版本 v${updates.currentVersion}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showUpdateDialog(context, check: true),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '自动检查新版本',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          '仅检查并提示，点击更新后才下载安装',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: updates.autoCheck,
                        onChanged: updates.setAutoCheck,
                      ),
                    ],
                  ),
                ),
                const Divider(),
                const SizedBox(height: 14),
                const Text(
                  '我的昵称',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: nickCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '显示给局域网内其他人',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '文件下载目录',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        downloadDir ?? '默认（${store.defaultDownloadsDir.path}）',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      child: const Text('选择'),
                      onPressed: () async {
                        final dir = await FilePicker.getDirectoryPath();
                        if (dir == null) return;
                        final granted = await StoragePerm.isGranted();
                        if (!granted && ctx.mounted) {
                          final go = await showDialog<bool>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              title: const Text('需要授权'),
                              content: const Text(
                                '保存到公共目录需要「所有文件访问」权限。\n去系统设置里为 LanChat 开启后，重新选择目录即可。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dctx).pop(false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(dctx).pop(true),
                                  child: const Text('去设置'),
                                ),
                              ],
                            ),
                          );
                          if (go == true) await StoragePerm.request();
                          return;
                        }
                        setState(() => downloadDir = dir);
                      },
                    ),
                  ],
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () async {
                      final g = await StoragePerm.isGranted();
                      setState(() => storageGranted = g);
                    },
                    child: Row(
                      children: [
                        Icon(
                          storageGranted
                              ? Icons.check_circle
                              : Icons.error_outline,
                          size: 14,
                          color: storageGranted ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            storageGranted
                                ? '已获「所有文件访问」授权，可保存到任意目录'
                                : '未授权「所有文件访问」，只能保存到应用私有目录（点击刷新状态）',
                            style: TextStyle(
                              fontSize: 11,
                              color: storageGranted
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('自动接收文件', style: TextStyle(fontSize: 13.5)),
                  subtitle: const Text(
                    '关闭后，对方发来的文件会被拒收',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  value: autoAccept,
                  onChanged: (v) => setState(() => autoAccept = v),
                ),
                const SizedBox(height: 4),
                Text(
                  '设备 ID：${cfg.deviceId.substring(0, 8)}…',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await cfg.update(
                nickname: nickCtrl.text,
                downloadDir: downloadDir,
                downloadDirSet: true,
                autoAccept: autoAccept,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  nickCtrl.dispose();
}
