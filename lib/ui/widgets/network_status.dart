import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/discovery.dart';

Future<void> showNetworkStatus(BuildContext context, Discovery discovery) {
  return showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: discovery,
      builder: (context, _) => AlertDialog(
        title: const Text('网络诊断'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(discovery.report),
                const SizedBox(height: 16),
                Text(
                  Platform.isMacOS
                      ? '请在系统设置 → 隐私与安全性 → 本地网络中允许 LanChat；两端需要连接同一局域网。'
                      : '请确认两端连接同一局域网，并允许 LanChat 通过防火墙。',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: discovery.report)),
            child: const Text('复制诊断'),
          ),
          TextButton(
            onPressed: () => discovery.refresh(force: true),
            child: const Text('重新连接'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
