import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../core/clipboard_attachments.dart';
import '../core/message_text.dart';
import '../core/outbox.dart';
import '../core/storage_perm.dart';
import '../core/store.dart';
import '../core/util.dart';
import '../models/message.dart';
import '../state/chats_model.dart';
import '../state/peers_model.dart';
import 'widgets/bubble.dart';
import 'app_theme.dart';

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
  bool _codeMode = false;
  bool _savingText = false;
  bool _pasting = false;
  bool _composerFocused = false;
  int _lastCount = 0;
  final Set<String> _selected = {};
  bool _selecting = false;
  late final ChatsModel _draftStore;

  @override
  void initState() {
    super.initState();
    _draftStore = context.read<ChatsModel>();
    final draft = _draftStore.drafts[widget.peerId];
    if (draft != null) {
      _input.text = draft.text;
      _codeMode = draft.codeMode;
    }
  }

  @override
  void dispose() {
    if (_input.text.isEmpty) {
      _draftStore.drafts.remove(widget.peerId);
    } else {
      _draftStore.drafts[widget.peerId] = (
        text: _input.text,
        codeMode: _codeMode,
      );
    }
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
    final peerId = widget.peerId;
    final chats = context.read<ChatsModel>();
    final outbox = context.read<Outbox>();
    try {
      chats.deleteFor(peerId, ids);
      await outbox.remove(peerId, ids);
      if (mounted && widget.peerId == peerId) _exitSelecting();
    } catch (_) {
      if (mounted) _showError('删除失败，请检查存储空间和文件权限');
    }
  }

  Future<void> _showBackgroundMenu(Offset globalPos) async {
    final peerId = widget.peerId;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final local = overlay.globalToLocal(globalPos);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromSize(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        overlay.size,
      ),
      items: const [PopupMenuItem(value: 'clear', child: Text('清空聊天'))],
    );
    if (action != 'clear' || !mounted || widget.peerId != peerId) return;
    final ids = {
      ...context.read<ChatsModel>().historyFor(peerId).map((m) => m.id),
      ...context.read<Outbox>().viewFor(peerId).map((m) => m.id),
    };
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 440),
        title: const Text('清空当前聊天？'),
        content: const Text(
          '将清空本机当前会话的聊天记录，并移除待发送消息。已接收的文件会保留，对方的记录不受影响。正在传输的内容可能已送达。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    // Do not clear another conversation if navigation happened during the dialog.
    if (ok == true && mounted && widget.peerId == peerId) {
      await _deleteMessages(ids);
    }
  }

  Future<void> _confirmDeleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $n 条消息？'),
        content: const Text('仅删除本机聊天记录，不影响对方设备；已接收的文件仍保留在下载目录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await _deleteMessages(Set<String>.of(_selected));
  }

  /// Copies a received file to a user-chosen directory (Android users
  /// otherwise can't reach the app-private download dir from other apps).
  Future<void> _saveFileTo(ChatMessage msg) async {
    final src = msg.filePath;
    if (src == null || !File(src).existsSync()) return;
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    if (!mounted) return;

    // same gate as the settings dialog: public dirs need all-files access
    if (!await StoragePerm.isGranted()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要授权'),
          content: const Text(
            '保存到公共目录需要「所有文件访问」权限。\n去系统设置里为 LanChat 开启后，重新操作即可。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true) await StoragePerm.request();
      return;
    }

    var target = File(p.join(dir, p.basename(src)));
    if (target.existsSync()) {
      final stem = p.basenameWithoutExtension(src);
      final ext = p.extension(src);
      var i = 1;
      while (target.existsSync()) {
        target = File(p.join(dir, '$stem ($i)$ext'));
        i++;
      }
    }
    try {
      await File(src).copy(target.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存到 ${target.path}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('保存失败：目录不可写'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _showMsgMenu(ChatMessage msg, Offset globalPos) async {
    final canSave =
        msg.kind == MsgKind.file &&
        msg.filePath != null &&
        File(msg.filePath!).existsSync();
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
              if (canSave)
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: const Text('保存到指定目录'),
                  onTap: () => Navigator.of(ctx).pop('save'),
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
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          globalPos.dx,
          globalPos.dy,
          overlay.size.width - globalPos.dx,
          overlay.size.height - globalPos.dy,
        ),
        items: [
          const PopupMenuItem(value: 'delete', height: 40, child: Text('删除该条')),
          if (canSave)
            const PopupMenuItem(
              value: 'save',
              height: 40,
              child: Text('保存到指定目录'),
            ),
          const PopupMenuItem(value: 'select', height: 40, child: Text('多选')),
        ],
      );
    }
    if (!mounted) return;
    switch (action) {
      case 'delete':
        await _deleteMessages({msg.id});
      case 'save':
        await _saveFileTo(msg);
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
    if (_savingText ||
        (_input.value.composing.isValid &&
            !_input.value.composing.isCollapsed)) {
      return;
    }
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _sendText(text);
  }

  Future<void> _sendText(String text) async {
    setState(() => _savingText = true);
    try {
      await context.read<Outbox>().sendText(
        widget.peerId,
        _codeMode ? encodeCode(text) : text,
      );
      if (mounted && _input.text == text) _input.clear();
    } catch (_) {
      if (mounted) _showError('消息保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingText = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _queueFile(Outbox outbox, String peerId, String path) async {
    try {
      await outbox.sendFile(peerId, path);
    } catch (error) {
      if (mounted) _showError('无法发送 ${p.basename(path)}：$error');
    }
  }

  Future<void> _pickFiles() async {
    final outbox = context.read<Outbox>();
    final peerId = widget.peerId;
    FilePickerResult? res;
    try {
      res = await FilePicker.pickFiles(allowMultiple: true);
    } catch (_) {
      if (mounted) _showError('无法打开文件选择器，请检查应用文件访问权限；也可将文件拖入聊天窗口');
      return;
    }
    if (res == null) return;
    for (final f in res.files) {
      final path = f.path;
      if (path != null) await _queueFile(outbox, peerId, path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final peers = context.watch<PeersModel>();
    final chats = context.watch<ChatsModel>();
    final outbox = context.watch<Outbox>();
    final peer = peers.byId(widget.peerId);
    if (peer == null) {
      return const Center(
        child: Text('该设备已从列表移除', style: TextStyle(color: Colors.grey)),
      );
    }
    final online = peers.isOnline(peer.id);
    final msgs = mergedChatView(
      chats.historyFor(peer.id),
      outbox.viewFor(peer.id),
    );
    if (msgs.length > _lastCount) {
      _lastCount = msgs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else {
      _lastCount = msgs.length;
    }

    Widget listArea = GestureDetector(
      key: const ValueKey('chat-background'),
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _showBackgroundMenu(d.globalPosition),
      child: Stack(
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
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.08),
                child: const Center(
                  child: Text(
                    '松开即发送',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!Platform.isAndroid) {
      listArea = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          final ob = context.read<Outbox>();
          for (final f in details.files) {
            _queueFile(ob, widget.peerId, f.path);
          }
        },
        child: listArea,
      );
    }

    return PopScope(
      // narrow (phone) layout: system back returns to the peer list
      // instead of leaving the app
      canPop: widget.onBack == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack?.call();
      },
      child: Column(
        children: [
          _header(context, peer.name, peer.platform, online),
          const Divider(height: 1),
          Expanded(child: listArea),
          _inputBar(context),
        ],
      ),
    );
  }

  Widget _buildRow(ChatMessage msg) {
    final bubble = MessageBubble(msg: msg);
    if (_selecting) {
      final sel = _selected.contains(msg.id);
      return GestureDetector(
        // absorb pointer events so taps anywhere on the row toggle selection
        // instead of reaching the (selectable) text or image
        onTap: () => setState(
          () => sel ? _selected.remove(msg.id) : _selected.add(msg.id),
        ),
        child: AbsorbPointer(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                sel ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: sel
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
              const SizedBox(width: 6),
              Expanded(child: bubble),
            ],
          ),
        ),
      );
    }
    return MessageBubble(
      msg: msg,
      onLongPressStart: (d) => _showMsgMenu(msg, d.globalPosition),
      onSecondaryTapUp: (d) => _showMsgMenu(msg, d.globalPosition),
    );
  }

  Widget _header(
    BuildContext context,
    String name,
    String platform,
    bool online,
  ) {
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
            Text(
              '已选 ${_selected.length} 条',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            TextButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => setState(() => _selected.clear()),
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
    final scheme = Theme.of(context).colorScheme;
    final status = online ? const Color(0xFF28AD83) : scheme.onSurfaceVariant;
    final label = switch (platform) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'android' => 'Android',
      _ => '设备',
    };
    return Container(
      height: 78,
      color: scheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          if (widget.onBack != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 21),
              tooltip: '返回',
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 4),
          ],
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: .09),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              switch (platform) {
                'android' => Icons.phone_android_rounded,
                'macos' => Icons.laptop_mac_rounded,
                _ => Icons.desktop_windows_rounded,
              },
              size: 22,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.circle, size: 6, color: status),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        online ? '$label · 在线' : '离线 · 上线后自动送达',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: status),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.folder_open_outlined, size: 20),
              tooltip: '打开下载目录',
              onPressed: () {
                final dir = context.read<Config>().effectiveDownloadDir(
                  context.read<AppStore>(),
                );
                revealInFolder(dir.path);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _paste() async {
    if (_pasting) return;
    _pasting = true;
    final peerId = widget.peerId;
    final store = context.read<AppStore>();
    final outbox = context.read<Outbox>();
    try {
      List<String> paths;
      try {
        paths = await ClipboardAttachments.read(store);
      } on MissingPluginException {
        paths = [];
      }
      if (!mounted || widget.peerId != peerId) return;
      if (paths.isNotEmpty) {
        for (final path in paths) {
          await _queueFile(outbox, peerId, path);
        }
      } else {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!mounted || widget.peerId != peerId || data?.text == null) return;
        final value = _input.value;
        final start = value.selection.isValid
            ? value.selection.start
            : value.text.length;
        final end = value.selection.isValid
            ? value.selection.end
            : value.text.length;
        _input.value = TextEditingValue(
          text: value.text.replaceRange(start, end, data!.text!),
          selection: TextSelection.collapsed(offset: start + data.text!.length),
        );
      }
    } catch (_) {
      if (mounted) _showError('无法粘贴文件或图片，请重新复制后重试，也可使用附件按钮');
    } finally {
      _pasting = false;
    }
  }

  Future<void> _insertKeyboardContent(KeyboardInsertedContent content) async {
    final peerId = widget.peerId;
    final store = context.read<AppStore>();
    final outbox = context.read<Outbox>();
    try {
      final data = content.data;
      final paths = data != null && data.isNotEmpty
          ? [await ClipboardAttachments.saveImage(store, data)]
          : await ClipboardAttachments.importFiles(store, [content.uri]);
      if (!mounted || widget.peerId != peerId) return;
      for (final path in paths) {
        await _queueFile(outbox, peerId, path);
      }
    } catch (_) {
      if (mounted) _showError('无法读取键盘中的图片，请重新复制后粘贴');
    }
  }

  void _insertNewline() {
    final value = _input.value;
    final start = value.selection.isValid
        ? value.selection.start
        : value.text.length;
    final end = value.selection.isValid
        ? value.selection.end
        : value.text.length;
    _input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    // Let the IME commit a selected Chinese/Japanese candidate first.
    if (_input.value.composing.isValid && !_input.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed || keyboard.isControlPressed) {
      _insertNewline();
    } else {
      _send();
    }
    return KeyEventResult.handled;
  }

  Widget _inputBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: ChatPalette.of(context).canvas,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _composerFocused
                ? scheme.primary.withValues(alpha: .7)
                : scheme.outlineVariant,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .12 : .025),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_codeMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Icon(Icons.code_rounded, color: scheme.primary, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      '代码片段',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '保留缩进与空行',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Actions(
              actions: <Type, Action<Intent>>{
                PasteTextIntent: CallbackAction<PasteTextIntent>(
                  onInvoke: (_) {
                    _paste();
                    return null;
                  },
                ),
              },
              child: Focus(
                onKeyEvent: _onComposerKey,
                onFocusChange: (focused) =>
                    setState(() => _composerFocused = focused),
                child: TextField(
                  key: const ValueKey('message-composer'),
                  controller: _input,
                  contentInsertionConfiguration: ContentInsertionConfiguration(
                    allowedMimeTypes: const ['image/*'],
                    onContentInserted: _insertKeyboardContent,
                  ),
                  contextMenuBuilder: (context, editable) =>
                      AdaptiveTextSelectionToolbar.buttonItems(
                        anchors: editable.contextMenuAnchors,
                        buttonItems: [
                          ...editable.contextMenuButtonItems.where(
                            (item) => item.type != ContextMenuButtonType.paste,
                          ),
                          ContextMenuButtonItem(
                            label: '粘贴',
                            type: ContextMenuButtonType.paste,
                            onPressed: () {
                              editable.hideToolbar();
                              _paste();
                            },
                          ),
                        ],
                      ),
                  autofocus: !Platform.isAndroid,
                  minLines: 2,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    fontFamily: _codeMode
                        ? (Platform.isMacOS
                              ? 'Menlo'
                              : Platform.isWindows
                              ? 'Consolas'
                              : 'monospace')
                        : null,
                  ),
                  decoration: InputDecoration(
                    hintText: _codeMode ? '在这里粘贴代码…' : '发送消息、链接，或粘贴文件与图片…',
                    filled: false,
                    contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 21,
                      ),
                      tooltip: '选择文件',
                      onPressed: _pickFiles,
                    ),
                    IconButton(
                      icon: const Icon(Icons.code_rounded, size: 21),
                      isSelected: _codeMode,
                      color: _codeMode ? scheme.primary : null,
                      tooltip: _codeMode ? '切换为普通文字' : '切换为代码消息',
                      onPressed: () => setState(() => _codeMode = !_codeMode),
                    ),
                    if (Platform.isAndroid)
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_return_rounded,
                          size: 19,
                        ),
                        tooltip: '换行',
                        onPressed: _insertNewline,
                      ),
                    const Spacer(),
                    if (constraints.maxWidth > 470) ...[
                      Text(
                        'Enter 发送 · Shift/Ctrl+Enter 换行',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 14),
                    ],
                    Tooltip(
                      message: '发送',
                      child: FilledButton.icon(
                        onPressed: _savingText ? null : _send,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          minimumSize: const Size(0, 36),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                        label: const Text('发送', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
