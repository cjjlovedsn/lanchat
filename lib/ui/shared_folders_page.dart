import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/clipboard_attachments.dart';
import '../core/config.dart';
import '../core/outbox.dart';
import '../core/shared_folders.dart';
import '../core/storage_perm.dart';
import '../core/store.dart';
import '../models/shared_folder.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import '../state/transfers_model.dart';

Future<bool> _folderAccess(BuildContext context) async {
  if (await StoragePerm.isGranted()) return true;
  if (!context.mounted) return false;
  final allow = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要文件访问权限'),
      content: const Text('访问手机公共文件夹需要为 LanChat 开启“所有文件访问”权限。开启后请重新选择文件夹。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('去设置'),
        ),
      ],
    ),
  );
  if (allow == true) await StoragePerm.request();
  return false;
}

void openSharedFolder(
  BuildContext context,
  String peerId,
  FolderInvite invite,
) {
  final peer = context.read<PeersModel>().byId(peerId);
  if (peer == null) return;
  final client = SharedFolderClient(
    config: context.read<Config>(),
    peer: peer,
    invite: invite,
    transfers: context.read<TransfersModel?>(),
  );
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          SharedFolderBrowser(client: client, store: context.read<AppStore>()),
    ),
  );
}

class SharedFoldersPage extends StatefulWidget {
  final String peerId;
  const SharedFoldersPage({super.key, required this.peerId});
  @override
  State<SharedFoldersPage> createState() => _SharedFoldersPageState();
}

class _SharedFoldersPageState extends State<SharedFoldersPage> {
  bool _adding = false;
  String? _error;

  Future<void> _add() async {
    if (_adding) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    final shares = context.read<SharedFolders>();
    final outbox = context.read<Outbox>();
    FolderGrant? grant;
    try {
      if (!await _folderAccess(context) || !mounted) return;
      final folder = await FilePicker.getDirectoryPath(
        dialogTitle: '选择要共享给对方的文件夹',
      );
      if (folder == null || !mounted) return;
      var writable = false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: const Text('共享此文件夹？'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(folder),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许对方写入文件'),
                    subtitle: const Text('关闭时，对方只能浏览和复制文件。'),
                    value: writable,
                    onChanged: (v) => update(() => writable = v),
                  ),
                  const Text(
                    '仅共享给当前聊天中的设备。双方应用在线时可访问，你可以随时取消共享。同名上传会自动改名，保留原文件。',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认共享'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      grant = await shares.add(widget.peerId, folder, writable: writable);
      await outbox.sendText(widget.peerId, grant.invite.encode());
    } catch (_) {
      if (grant != null) {
        try {
          shares.revoke(grant.invite.id);
        } catch (_) {}
      }
      if (mounted) setState(() => _error = '共享失败，请检查文件夹权限和存储空间后重试');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _change(VoidCallback action) {
    try {
      action();
    } catch (_) {
      setState(() => _error = '无法保存共享设置，请重试');
    }
  }

  Future<void> _revoke(FolderGrant grant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('取消共享“${grant.invite.name}”？'),
        content: const Text('对方将无法继续访问此入口，已经复制出去的文件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消共享'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _change(() => context.read<SharedFolders>().revoke(grant.invite.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final shares = context.watch<SharedFolders>();
    final local = shares.forPeer(widget.peerId);
    final remote = <String, FolderInvite>{};
    for (final msg in context.watch<ChatsModel>().historyFor(widget.peerId)) {
      final invite = FolderInvite.parse(msg.text);
      if (!msg.outgoing && invite != null) remote[invite.id] = invite;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('共享文件夹')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          FilledButton.icon(
            onPressed: _adding ? null : _add,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: Text(_adding ? '正在共享…' : '共享本机文件夹'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 24),
          Text('我共享给对方的', style: Theme.of(context).textTheme.titleMedium),
          if (local.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('尚未共享文件夹。共享后会在聊天中发送一个入口。'),
            ),
          for (final grant in local)
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: Text(grant.invite.name),
                    subtitle: Text(grant.root),
                    trailing: IconButton(
                      tooltip: '取消共享',
                      icon: const Icon(Icons.link_off),
                      onPressed: () => _revoke(grant),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('允许对方写入文件'),
                    value: grant.writable,
                    onChanged: (v) =>
                        _change(() => shares.setWritable(grant.invite.id, v)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text('对方共享给我的', style: Theme.of(context).textTheme.titleMedium),
          if (remote.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('对方共享后，可在这里或聊天中的文件夹卡片打开。双方均需使用支持共享文件夹的版本。'),
            ),
          for (final invite in remote.values)
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_shared_outlined),
                title: Text(invite.name),
                subtitle: const Text('点击浏览 · 需要对方在线'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openSharedFolder(context, widget.peerId, invite),
              ),
            ),
        ],
      ),
    );
  }
}

class SharedFolderBrowser extends StatefulWidget {
  final SharedFolderClient client;
  final AppStore store;
  const SharedFolderBrowser({
    super.key,
    required this.client,
    required this.store,
  });
  @override
  State<SharedFolderBrowser> createState() => _SharedFolderBrowserState();
}

class _SharedFolderBrowserState extends State<SharedFolderBrowser> {
  String _path = '';
  FolderListing? _listing;
  final Set<String> _selected = {};
  bool _busy = false;
  bool _cancelled = false;
  bool _dragging = false;
  String? _error;
  String? _status;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    widget.client.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _status = null;
      _progress = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _cancelled
              ? '已取消'
              : error is FormatException
              ? error.message
              : '操作未完成，请确认对方在线、文件权限和可用空间后重试',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _load(String path) async {
    _checkCancelled();
    final listing = await widget.client.list(path);
    if (mounted) {
      setState(() {
        _path = path;
        _listing = listing;
        _selected.clear();
      });
    }
  }

  Future<void> _refresh() => _run(() => _load(_path));
  void _checkCancelled() {
    if (_cancelled || !mounted) throw const FormatException('已取消');
  }

  void _cancel() {
    _cancelled = true;
    widget.client.cancel();
  }

  void _progressFor(String name, double progress) {
    if (mounted) {
      setState(() {
        _status = name;
        _progress = progress;
      });
    }
  }

  Future<void> _upload(List<String> paths) async {
    if (_listing?.writable != true) {
      throw const FormatException('此共享文件夹为只读，需由对方允许写入');
    }
    if (paths.isEmpty) throw const FormatException('没有可粘贴的文件或图片');
    var skipped = 0;
    var completed = 0;
    for (final path in paths) {
      _checkCancelled();
      final name = p.basename(path);
      void progress(double value) => _progressFor(
        '上传 $name（${completed + 1}/${paths.length}）',
        (completed + value) / paths.length,
      );
      try {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          final report = await widget.client.uploadDirectory(
            _path,
            Directory(path),
            progress: progress,
          );
          skipped += report.skippedLinks;
        } else if (type == FileSystemEntityType.file) {
          await widget.client.upload(_path, File(path), progress: progress);
        } else {
          throw const FormatException('所选项目不可读取，不支持符号链接');
        }
        completed++;
      } catch (error) {
        throw FormatException(
          '“$name”上传未完成，此前已完成 $completed 项。${error is FormatException ? error.message : '请检查网络和文件权限后重试，可刷新查看结果。'}',
        );
      }
    }
    await _load(_path);
    if (mounted) {
      setState(
        () => _status =
            '已上传 ${paths.length} 项；同名文件夹和文件自动改名${skipped > 0 ? '；跳过 $skipped 个符号链接' : ''}',
      );
    }
  }

  Future<void> _paste() => _run(() async {
    if (_listing?.writable != true) throw const FormatException('此共享文件夹为只读');
    await _upload(
      await ClipboardAttachments.read(widget.store, allowDirectories: true),
    );
  });
  Future<void> _pick() => _run(() async {
    final picked = await FilePicker.pickFiles(allowMultiple: true);
    if (picked == null) return;
    await _upload(picked.files.map((f) => f.path).whereType<String>().toList());
  });

  Future<void> _pickDirectory() => _run(() async {
    if (!await _folderAccess(context) || !mounted) return;
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要上传的整个文件夹',
    );
    if (folder != null) await _upload([folder]);
  });

  Future<void> _copyOrSave({
    required bool copy,
    bool currentFolder = false,
  }) => _run(() async {
    if (_selected.isEmpty && !currentFolder) return;
    Directory destination;
    if (copy) {
      // Retain copied files so Finder/Explorer can paste them after this page closes.
      final cache = Directory(p.join(widget.store.base.path, 'shared-copies'))
        ..createSync(recursive: true);
      destination = await cache.createTemp('copy-');
    } else {
      if (!await _folderAccess(context) || !mounted) return;
      final folder = await FilePicker.getDirectoryPath(dialogTitle: '保存共享文件到');
      if (folder == null) return;
      destination = Directory(folder);
    }
    var copied = false;
    try {
      final files = <String>[];
      var skipped = 0;
      var completed = 0;
      final selected = currentFolder
          ? [
              FolderEntry(
                name: _path.isEmpty
                    ? widget.client.invite.name
                    : p.posix.basename(_path),
                directory: true,
              ),
            ]
          : _listing!.entries
                .where((entry) => _selected.contains(entry.name))
                .toList();
      for (final entry in selected) {
        final name = entry.name;
        _checkCancelled();
        void progress(double value) => _progressFor(
          '下载 $name（${completed + 1}/${selected.length}）',
          (completed + value) / selected.length,
        );
        try {
          if (entry.directory) {
            final report = await widget.client.downloadDirectory(
              currentFolder ? _path : p.posix.join(_path, name),
              destination,
              progress: progress,
            );
            files.add(report.path);
            skipped += report.skippedLinks;
          } else {
            final file = await widget.client.download(
              p.posix.join(_path, name),
              destination,
              progress: progress,
            );
            files.add(file.path);
          }
          completed++;
        } catch (error) {
          throw FormatException(
            '“$name”下载未完成。${copy ? '剪贴板未更新。' : '此前已保存 $completed 项。'}${error is FormatException ? error.message : '请检查网络、文件权限和可用空间后重试。'}',
          );
        }
      }
      _checkCancelled();
      if (copy) {
        if (!await Pasteboard.writeFiles(files)) {
          throw const FormatException('无法写入系统剪贴板，请改用“保存到…”');
        }
        copied = true;
      }
      if (mounted) {
        setState(
          () => _status = copy
              ? '已复制 ${files.length} 项，可到访达或资源管理器粘贴${skipped > 0 ? '；跳过 $skipped 个符号链接' : ''}'
              : '已保存 ${files.length} 项${skipped > 0 ? '；跳过 $skipped 个符号链接' : ''}',
        );
      }
      if (copy) {
        // Keep only the latest successful clipboard copy; large videos must
        // not accumulate every time the user copies them again.
        try {
          await for (final old in destination.parent.list(followLinks: false)) {
            if (old is Directory &&
                old.path != destination.path &&
                p.basename(old.path).startsWith('copy-')) {
              await old.delete(recursive: true);
            }
          }
        } catch (_) {}
      }
    } finally {
      if (copy && !copied) {
        try {
          await destination.delete(recursive: true);
        } catch (_) {}
      }
    }
  });

  Future<void> _menu(Offset at) async {
    if (_busy) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(at.dx, at.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        if (_selected.isNotEmpty && !Platform.isAndroid)
          const PopupMenuItem(value: 'copy', child: Text('复制文件')),
        if (_selected.isNotEmpty)
          const PopupMenuItem(value: 'save', child: Text('保存到…')),
        PopupMenuItem(
          value: 'paste',
          enabled: _listing?.writable == true,
          child: const Text('粘贴文件'),
        ),
        const PopupMenuItem(value: 'refresh', child: Text('刷新')),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'copy':
        await _copyOrSave(copy: true);
      case 'save':
        await _copyOrSave(copy: false);
      case 'paste':
        await _paste();
      case 'refresh':
        await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final writable = _listing?.writable == true;
    Widget content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _menu(d.globalPosition),
      child: _listing == null
          ? Center(child: Text(_busy ? '正在连接共享文件夹…' : '暂时无法访问，可点击刷新重试'))
          : _listing!.entries.isEmpty
          ? const Center(child: Text('文件夹为空'))
          : ListView.builder(
              itemCount: _listing!.entries.length,
              itemBuilder: (context, index) {
                final entry = _listing!.entries[index];
                return ListTile(
                  leading: Checkbox(
                    value: _selected.contains(entry.name),
                    onChanged: _busy
                        ? null
                        : (_) => setState(() {
                            if (!_selected.add(entry.name)) {
                              _selected.remove(entry.name);
                            }
                          }),
                  ),
                  title: Row(
                    children: [
                      if (entry.directory) ...[
                        const Icon(Icons.folder_outlined, size: 20),
                        const SizedBox(width: 8),
                      ],
                      Expanded(child: Text(entry.name)),
                    ],
                  ),
                  subtitle: entry.directory
                      ? const Text('文件夹')
                      : Text('${(entry.size / 1024).toStringAsFixed(1)} KB'),
                  trailing: entry.directory
                      ? const Icon(Icons.chevron_right)
                      : null,
                  onTap: _busy
                      ? null
                      : () {
                          if (entry.directory) {
                            _run(() => _load(p.posix.join(_path, entry.name)));
                          } else {
                            setState(() {
                              if (!_selected.add(entry.name)) {
                                _selected.remove(entry.name);
                              }
                            });
                          }
                        },
                );
              },
            ),
    );
    if (!Platform.isAndroid) {
      content = DropTarget(
        onDragEntered: (_) {
          if (writable && !_busy) setState(() => _dragging = true);
        },
        onDragExited: (_) {
          if (mounted) setState(() => _dragging = false);
        },
        onDragDone: (d) {
          setState(() => _dragging = false);
          _run(() => _upload(d.files.map((f) => f.path).toList()));
        },
        child: content,
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
        if (!Platform.isAndroid) ...{
          const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
              _copyOrSave(copy: true),
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
              _copyOrSave(copy: true),
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.client.invite.name),
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                tooltip: '整个当前文件夹',
                enabled: !_busy && _listing != null,
                onSelected: (action) =>
                    _copyOrSave(copy: action == 'copy', currentFolder: true),
                itemBuilder: (_) => [
                  if (!Platform.isAndroid)
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('复制整个当前文件夹'),
                    ),
                  const PopupMenuItem(
                    value: 'save',
                    child: Text('保存整个当前文件夹到…'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '上一级',
                      onPressed: _busy || _path.isEmpty
                          ? null
                          : () => _run(
                              () => _load(
                                p.posix.dirname(_path) == '.'
                                    ? ''
                                    : p.posix.dirname(_path),
                              ),
                            ),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    Expanded(
                      child: Text(
                        '/$_path',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Chip(label: Text(writable ? '可写入' : '只读')),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy || !writable ? null : _paste,
                      icon: const Icon(Icons.content_paste, size: 18),
                      label: const Text('粘贴文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !writable ? null : _pick,
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text('上传文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !writable ? null : _pickDirectory,
                      icon: const Icon(
                        Icons.drive_folder_upload_outlined,
                        size: 18,
                      ),
                      label: const Text('上传文件夹'),
                    ),
                    if (!Platform.isAndroid)
                      OutlinedButton.icon(
                        onPressed: _busy || _selected.isEmpty
                            ? null
                            : () => _copyOrSave(copy: true),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('复制文件'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _busy || _selected.isEmpty
                          ? null
                          : () => _copyOrSave(copy: false),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('保存到…'),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  '勾选文件或文件夹后复制、保存；点击文件夹名称进入。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(value: _progress),
                      ),
                      TextButton(onPressed: _cancel, child: const Text('取消')),
                    ],
                  ),
                ),
              if (_error != null || _status != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error ?? _status!,
                    style: TextStyle(
                      color: _error == null
                          ? null
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: content),
                    if (_dragging)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: Color(0x224488ff),
                            child: Center(child: Text('松开以上传到当前共享文件夹')),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
