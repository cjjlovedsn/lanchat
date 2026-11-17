import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/util.dart';
import '../../models/message.dart';
import '../../models/shared_folder.dart';
import '../../state/transfers_model.dart';
import 'image_viewer.dart';
import 'message_text.dart';
import 'video_viewer.dart';
import 'video_poster.dart';
import '../app_theme.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureLongPressStartCallback? onLongPressStart;
  final VoidCallback? onOpenSharedFolder;
  const MessageBubble({
    super.key,
    required this.msg,
    this.onSecondaryTapUp,
    this.onLongPressStart,
    this.onOpenSharedFolder,
  });

  @override
  Widget build(BuildContext context) {
    final out = msg.outgoing;
    final scheme = Theme.of(context).colorScheme;
    final palette = ChatPalette.of(context);
    final shared = FolderInvite.parse(msg.text);
    final metaColor = out
        ? palette.onOutgoing.withValues(alpha: .88)
        : scheme.onSurfaceVariant;

    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: onSecondaryTapUp,
        onLongPressStart: onLongPressStart,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width < 640
                ? MediaQuery.sizeOf(context).width * .8
                : 480,
          ),
          decoration: BoxDecoration(
            color: out ? palette.outgoing : palette.incoming,
            border: out
                ? null
                : Border.all(
                    color: scheme.outlineVariant.withValues(alpha: .55),
                  ),
            boxShadow: [
              if (!out)
                BoxShadow(
                  color: Colors.black.withValues(alpha: .025),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
            ],
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(out ? 16 : 5),
              bottomRight: Radius.circular(out ? 5 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (shared != null)
                InkWell(
                  onTap: onOpenSharedFolder,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_shared_outlined, size: 30),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                shared.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                out ? '共享文件夹 · 点击管理' : '共享文件夹 · 点击浏览',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: metaColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (msg.kind == MsgKind.text)
                MessageText(
                  text: msg.text ?? '',
                  color: out ? palette.onOutgoing : scheme.onSurface,
                )
              else
                FileCard(msg: msg),
              const SizedBox(height: 5),
              _meta(context, metaColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(BuildContext context, Color color) {
    final List<Widget> children = [
      Text(formatClock(msg.ts), style: TextStyle(fontSize: 10.5, color: color)),
    ];
    if (!msg.outgoing) {
      return Row(mainAxisSize: MainAxisSize.min, children: children);
    }

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
          Text(
            p != null ? '${(p * 100).round()}%' : '传输中',
            style: TextStyle(fontSize: 10.5, color: color),
          ),
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

  static const _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
  static const _videoExt = {'mp4', 'mkv', 'mov', 'avi', 'm4v', 'webm', '3gp'};

  static String? _extOf(String? name) {
    final n = name ?? '';
    final dot = n.lastIndexOf('.');
    if (dot <= 0 || dot == n.length - 1) return null;
    return n.substring(dot + 1).toLowerCase();
  }

  static IconData _iconFor(String? name) {
    final ext = (name ?? '').split('.').last.toLowerCase();
    switch (ext) {
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip_outlined;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
        return Icons.image_outlined;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'm4a':
        return Icons.audio_file_outlined;
      case 'mp4':
      case 'mkv':
      case 'mov':
      case 'avi':
        return Icons.movie_outlined;
      case 'exe':
      case 'msi':
      case 'dmg':
      case 'apk':
        return Icons.apps;
      case 'dart':
      case 'java':
      case 'py':
      case 'js':
      case 'ts':
      case 'json':
      case 'xml':
      case 'html':
      case 'css':
      case 'c':
      case 'cpp':
      case 'h':
      case 'cs':
      case 'go':
      case 'rs':
      case 'txt':
      case 'md':
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
    final ext = _extOf(msg.fileName);
    final isImage = _imageExt.contains(ext);
    final isVideo = _videoExt.contains(ext);
    final palette = ChatPalette.of(context);
    final dark = msg.outgoing
        ? palette.onOutgoing
        : Theme.of(context).colorScheme.onSurface;
    final sub = msg.outgoing
        ? palette.onOutgoing.withValues(alpha: .88)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    String hint;
    if (!hasLocal) {
      hint = '';
    } else if (isVideo) {
      hint = ' · 点击播放';
    } else if (isImage) {
      hint = ' · 点击查看';
    } else {
      hint = Platform.isAndroid ? ' · 点击打开' : ' · 点击定位';
    }

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
          child: isVideo
              ? Icon(
                  Icons.movie_outlined,
                  size: 24,
                  color: msg.outgoing
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary,
                )
              : Icon(
                  _iconFor(msg.fileName),
                  size: 22,
                  color: msg.outgoing
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary,
                ),
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
                  color: fileGone
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : dark,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${formatSize(msg.fileSize)}$hint',
                style: TextStyle(fontSize: 11, color: sub),
              ),
              if (fileGone) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.delete_outline,
                      size: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '文件已被清理或移动',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (isImage && hasLocal) {
      return InkWell(
        onTap: () => showImageViewer(context, path),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: 220,
            height: 165,
            fit: BoxFit.cover,
            cacheWidth: 440,
            errorBuilder: (_, __, ___) => card,
          ),
        ),
      );
    }

    if (!hasLocal) return card;
    return InkWell(
      onTap: () => isVideo
          ? showVideoViewer(context, path, msg.fileName ?? '视频')
          : openOrReveal(path),
      child: isVideo
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: VideoPoster(path: path),
                ),
                card,
              ],
            )
          : card,
    );
  }
}
