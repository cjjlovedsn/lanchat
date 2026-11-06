import 'dart:io';

import 'package:open_filex/open_filex.dart';

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

String two(int v) => v.toString().padLeft(2, '0');

String formatClock(DateTime dt) => '${two(dt.hour)}:${two(dt.minute)}';

String formatLastSeen(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays == 1) return '昨天 ${formatClock(dt)}';
  return '${dt.month}-${two(dt.day)} ${formatClock(dt)}';
}

/// Reveal a file in the platform file manager (with the file selected).
void revealInFolder(String path) {
  try {
    if (Platform.isWindows) {
      Process.run('explorer', ['/select,$path']);
    } else {
      Process.run('open', ['-R', path]);
    }
  } catch (_) {}
}

/// Open a received file: Android opens it with the system viewer,
/// desktop reveals it in the file manager.
Future<void> openOrReveal(String path) async {
  if (Platform.isAndroid) {
    try {
      await OpenFilex.open(path);
    } catch (_) {}
    return;
  }
  revealInFolder(path);
}

/// Strip characters that are illegal in file names on Windows/macOS.
String sanitizeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? 'file' : cleaned;
}
