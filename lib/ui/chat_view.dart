import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../core/outbox.dart';
import '../core/store.dart';
import '../core/util.dart';
import '../models/message.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import 'widgets/bubble.dart';

class ChatView extends StatefulWidget {
  final String peerId;
  final VoidCallback? onBack; // narrow (phone) layout: back to the list
  const ChatView({super.key, required this.peerId, this.onBack});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _dragging = false;
  int _lastCount = 0;
  final Set<String> _selected = {};
  bool _selecting = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _exitSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _deleteMessages(Set<String> ids) async {
    if (ids.isEmpty) return;
    context.read<ChatsModel>().deleteFor(widget.peerId, ids);
    await context.read<Outbox>().remove(widget.peerId, ids);
    _exitSelecting();
  }

  Future<void> _confirmDeleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $n 条消息？'),
        content: const Text('仅删除本机聊天记录，不影响对方设备；已接收的文件仍保留在下载目录。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _deleteMessages(Set<String>.of(_selected));
  }

  Future<void> _showMsgMenu(ChatMessage msg, Offset globalPos) async {
    String? action;
    if (Platform.isAndroid) {
      action = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除该条'),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('多选'),
                onTap: () => Navigator.of(ctx).pop('select'),
              ),
            ],
          ),
        ),
      );
    } else {
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
      action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          globalPos.dx,
          globalPos.dy,
          overlay.size.width - globalPos.dx,
          overlay.size.height - globalPos.dy,
        ),
        items: const [
          PopupMenuItem(value: 'delete', height: 40, child: Text('删除该条')),
          PopupMenuItem(value: 'select', height: 40, child: Text('多选')),
        ],
      );
    }
    if (!mounted) return;
    switch (action) {
      case 'delete':
        await _deleteMessages({msg.id});
      case 'select':
        setState(() {
          _selecting = true;
          _selected.add(msg.id);
        });
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    context.read<Outbox>().sendText(widget.peerId, text);
    _input.clear();
  }

  Future<void> _pickFiles() async {
    final outbox = context.read<Outbox>();
    final res = await FilePicker.pickFiles(allowMultiple: true);
    if (res == null) return;
    for (final f in res.files) {
      final path = f.path;
      if (path != null) await outbox.sendFile(widget.peerId, path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final peers = context.watch<PeersModel>();
    final chats = context.watch<ChatsModel>();
    final outbox = context.watch<Outbox>();
    final peer = peers.byId(widget.peerId);
    if (peer == null) {
      return const Center(child: Text('该设备已从列表移除', style: TextStyle(color: Colors.grey)));
    }
    final online = peers.isOnline(peer.id);
    final msgs = mergedChatView(chats.historyFor(peer.id), outbox.viewFor(peer.id));
    if (msgs.length > _lastCount) {
      _lastCount = msgs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else {
      _lastCount = msgs.length;
    }

    Widget listArea = Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          itemCount: msgs.length,
          itemBuilder: (context, i) => _buildRow(msgs[i]),
        ),
        if (_dragging)
          Positioned.fill(
            child: Container(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
              child: const Center(
                child: Text('松开即发送',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
      ],
    );
    if (!Platform.isAndroid) {
      listArea = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          final ob = context.read<Outbox>();
          for (final f in details.files) {
            ob.sendFile(widget.peerId, f.path);
          }
        },
        child: listArea,
      );
    }

    return Column(
      children: [
        _header(context, peer.name, peer.id, online),
        const Divider(height: 1),
        Expanded(child: listArea),
        const Divider(height: 1),
        _inputBar(context),
      ],
    );
  }

  Widget _buildRow(ChatMessage msg) {
    final bubble = MessageBubble(msg: msg);
    if (_selecting) {
      final sel = _selected.contains(msg.id);
      return GestureDetector(
        // absorb pointer events so taps anywhere on the row toggle selection
        // instead of reaching the (selectable) text or image
        onTap: () => setState(() => sel ? _selected.remove(msg.id) : _selected.add(msg.id)),
        child: AbsorbPointer(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                sel ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: sel ? Theme.of(context).colorScheme.primary : Colors.grey,
              ),
              const SizedBox(width: 6),
              Expanded(child: bubble),
            ],
          ),
        ),
      );
    }
    return GestureDetector(
      onLongPressStart: (d) => _showMsgMenu(msg, d.globalPosition),
      onSecondaryTapUp: (d) => _showMsgMenu(msg, d.globalPosition),
      child: bubble,
    );
  }

  Widget _header(BuildContext context, String name, String peerId, bool online) {
    if (_selecting) {
      return Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, size: 22),
              tooltip: '取消',
              onPressed: _exitSelecting,
            ),
            Text('已选 ${_selected.length} 条',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              onPressed: _selected.isEmpty ? null : () => setState(() => _selected.clear()),
              child: const Text('全不选'),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _selected.isEmpty ? null : _confirmDeleteSelected,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (widget.onBack != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 22),
              tooltip: '返回',
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: online ? const Color(0x1A44BD5C) : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              online ? '在线' : '离线，消息将在对方上线后送达',
              style: TextStyle(
                fontSize: 11,
                color: online ? const Color(0xFF2F9E44) : Colors.grey,
              ),
            ),
          ),
          const Spacer(),
          if (!Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.folder_open_outlined, size: 20),
              tooltip: '打开下载目录',
              onPressed: () {
                final dir = context
                    .read<Config>()
                    .effectiveDownloadDir(context.read<AppStore>());
                revealInFolder(dir.path);
              },
            ),
        ],
      ),
    );
  }

  Widget _inputBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: '选择文件',
            onPressed: _pickFiles,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _input,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: Platform.isAndroid
                    ? '输入消息'
                    : '输入消息，Enter 发送；可直接拖入文件',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            icon: const Icon(Icons.send, size: 18),
            tooltip: '发送',
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}
