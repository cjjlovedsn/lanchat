import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/util.dart';
import '../../models/message.dart';
import '../../state/transfers_model.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  const MessageBubble({super.key, required this.msg});

  @override
  Widget build(BuildContext context) {
    final out = msg.outgoing;
    final scheme = Theme.of(context).colorScheme;
    final metaColor = out ? Colors.white.withValues(alpha: 0.75) : Colors.grey;

    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: out ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(10),
            topRight: const Radius.circular(10),
            bottomLeft: Radius.circular(out ? 10 : 3),
            bottomRight: Radius.circular(out ? 3 : 10),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.kind == MsgKind.text)
              Text(
                msg.text ?? '',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: out ? Colors.white : scheme.onSurface,
                ),
              )
            else
              FileCard(msg: msg),
            const SizedBox(height: 5),
            _meta(context, metaColor),
          ],
        ),
      ),
    );
  }

  Widget _meta(BuildContext context, Color color) {
    final List<Widget> children = [
      Text(formatClock(msg.ts), style: TextStyle(fontSize: 10.5, color: color)),
    ];
    if (!msg.outgoing) return Row(mainAxisSize: MainAxisSize.min, children: children);

    switch (msg.state) {
      case SendState.pending:
        children.addAll([
          const SizedBox(width: 6),
          Icon(Icons.schedule, size: 12, color: color),
          const SizedBox(width: 2),
          Text('待送达', style: TextStyle(fontSize: 10.5, color: color)),
        ]);
      case SendState.sending:
        final p = context.watch<TransfersModel>().of(msg.id);
        children.addAll([
          const SizedBox(width: 6),
          if (p != null)
            SizedBox(
              width: 52,
              child: LinearProgressIndicator(
                value: p,
                minHeight: 3,
                backgroundColor: color.withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            )
          else
            Icon(Icons.schedule, size: 12, color: color),
          const SizedBox(width: 4),
          Text(p != null ? '${(p * 100).round()}%' : '传输中',
              style: TextStyle(fontSize: 10.5, color: color)),
        ]);
      case SendState.delivered:
        children.addAll([
          const SizedBox(width: 6),
          Icon(Icons.done, size: 13, color: color),
        ]);
      case SendState.refused:
        children.addAll([
          const SizedBox(width: 6),
          Icon(Icons.block, size: 12, color: color),
          const SizedBox(width: 2),
          Text('对方拒收', style: TextStyle(fontSize: 10.5, color: color)),
        ]);
      case SendState.received:
        break;
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class FileCard extends StatelessWidget {
  final ChatMessage msg;
  const FileCard({super.key, required this.msg});

  static IconData _iconFor(String? name) {
    final ext = (name ?? '').split('.').last.toLowerCase();
    switch (ext) {
      case 'zip': case 'rar': case '7z': case 'tar': case 'gz':
        return Icons.folder_zip_outlined;
      case 'png': case 'jpg': case 'jpeg': case 'gif': case 'webp': case 'bmp':
        return Icons.image_outlined;
      case 'mp3': case 'wav': case 'flac': case 'm4a':
        return Icons.audio_file_outlined;
      case 'mp4': case 'mkv': case 'mov': case 'avi':
        return Icons.movie_outlined;
      case 'exe': case 'msi': case 'dmg': case 'apk':
        return Icons.apps;
      case 'dart': case 'java': case 'py': case 'js': case 'ts': case 'json':
      case 'xml': case 'html': case 'css': case 'c': case 'cpp': case 'h':
      case 'cs': case 'go': case 'rs': case 'txt': case 'md':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = msg.filePath;
    final hasLocal = path != null && File(path).existsSync();
    final fileGone = !msg.outgoing && !hasLocal; // received file cleaned up
    final dark = msg.outgoing ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final sub = msg.outgoing ? Colors.white70 : Colors.grey;

    final card = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: msg.outgoing
                ? Colors.white.withValues(alpha: 0.15)
                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_iconFor(msg.fileName), size: 22, color: msg.outgoing ? Colors.white : Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                msg.fileName ?? '文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fileGone ? Colors.grey : dark,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${formatSize(msg.fileSize)}'
                '${hasLocal ? (Platform.isAndroid ? ' · 点击打开' : ' · 点击定位') : ''}',
                style: TextStyle(fontSize: 11, color: sub),
              ),
              if (fileGone) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delete_outline, size: 12, color: Colors.orange.shade700),
                    const SizedBox(width: 3),
                    Text(
                      '文件已被清理或移动',
                      style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (!hasLocal) return card;
    return InkWell(onTap: () => openOrReveal(path), child: card);
  }
}
