import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/store.dart';

Future<void> showSettingsDialog(BuildContext context) async {
  final cfg = context.read<Config>();
  final store = context.read<AppStore>();
  final nickCtrl = TextEditingController(text: cfg.nickname);
  String? downloadDir = cfg.downloadDir;
  bool autoAccept = cfg.autoAccept;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('设置'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('我的昵称', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
              const Text('文件下载目录',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      downloadDir ?? '默认（${store.defaultDownloadsDir.path}）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  TextButton(
                    child: const Text('选择'),
                    onPressed: () async {
                      final dir = await FilePicker.getDirectoryPath();
                      if (dir != null) setState(() => downloadDir = dir);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('自动接收文件', style: TextStyle(fontSize: 13.5)),
                subtitle: const Text('关闭后，对方发来的文件会被拒收',
                    style: TextStyle(fontSize: 11.5)),
                value: autoAccept,
                onChanged: (v) => setState(() => autoAccept = v),
              ),
              const SizedBox(height: 4),
              Text('设备 ID：${cfg.deviceId.substring(0, 8)}…',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
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
}
