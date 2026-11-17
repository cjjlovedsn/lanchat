import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_updates.dart';
import '../../state/transfers_model.dart';

Future<void> showUpdateDialog(
  BuildContext context, {
  bool check = false,
}) async {
  final updates = context.read<AppUpdates>();
  var closed = false;
  if (check) unawaited(updates.check());
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => Consumer<AppUpdates>(
      builder: (context, updater, _) {
        final release = updater.release;
        return PopScope(
          canPop: !updater.installing,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              closed = true;
              if (updater.downloading) updater.cancelDownload();
            }
          },
          child: AlertDialog(
            constraints: const BoxConstraints(maxWidth: 460),
            title: Text(release == null ? '检查更新' : '发现新版本 v${release.version}'),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前版本 v${updater.currentVersion}'),
                    const SizedBox(height: 12),
                    if (updater.checking)
                      const LinearProgressIndicator()
                    else if (release == null && updater.error == null)
                      const Text('已是最新正式版本'),
                    if (release != null) ...[
                      Text(
                        '安装包 ${(release.size / 1024 / 1024).toStringAsFixed(1)} MB · 下载后校验 SHA256',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      if (release.notes.isNotEmpty)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: SingleChildScrollView(
                            child: Text(release.notes),
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Text('点击更新后下载安装包，校验通过后再启动安装。聊天记录会保留。'),
                      if (Platform.isAndroid)
                        const Text('安装需要系统确认；若签名不同，会先说明原因。')
                      else
                        const Text('安装时会退出并替换当前应用，请先等待文件传输完成。'),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('此版本不再提示更新'),
                        subtitle: const Text('仅忽略此版本，后续新版本仍会提醒；可随时手动检查更新。'),
                        value: updater.isReleaseIgnored,
                        onChanged: updater.busy
                            ? null
                            : (value) =>
                                  updater.setIgnoreRelease(value ?? false),
                      ),
                    ],
                    if (updater.downloading) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: updater.progress),
                      const SizedBox(height: 6),
                      Text(
                        '正在下载 ${((updater.progress ?? 0) * 100).toStringAsFixed(0)}%',
                      ),
                    ],
                    if (updater.error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        updater.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: updater.installing
                    ? null
                    : () {
                        if (updater.downloading) updater.cancelDownload();
                        Navigator.of(context).pop();
                      },
                child: Text(updater.downloading ? '取消下载' : '稍后'),
              ),
              if (release == null)
                FilledButton(
                  onPressed: updater.busy ? null : () => updater.check(),
                  child: const Text('重新检查'),
                )
              else
                FilledButton(
                  onPressed: updater.busy
                      ? null
                      : () async {
                          if (updater.downloaded == null) {
                            await updater.download();
                          }
                          if (closed ||
                              !context.mounted ||
                              updater.downloaded == null) {
                            return;
                          }
                          if (context
                              .read<TransfersModel>()
                              .hasActiveTransfers) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('文件仍在传输，请完成后再点击安装')),
                            );
                            return;
                          }
                          final quit = await updater.install();
                          if (quit) {
                            await windowManager.destroy();
                            exit(0);
                          }
                        },
                  child: Text(
                    updater.installing
                        ? '准备安装…'
                        : updater.downloading
                        ? '正在下载…'
                        : updater.downloaded != null
                        ? '安装更新'
                        : '下载并安装',
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
  closed = true;
  if (updates.downloading) updates.cancelDownload();
}
