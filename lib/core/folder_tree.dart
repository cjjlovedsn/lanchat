import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'protocol.dart';
import 'util.dart';

const maxTreeEntries = 10000;
const maxTreeDepth = 64;
const treeFrameTimeout = Duration(minutes: 2);

typedef TreeProgress = void Function(double fraction);

/// Strict portable names also prevent traversal, Windows device paths and
/// alternate data streams. Reject rather than silently rename nested entries.
List<String> treeSegments(String relative) {
  final parts = relative.split('/');
  if (relative.isEmpty ||
      relative.length > 4096 ||
      parts.length > maxTreeDepth ||
      parts.any(
        (name) =>
            name.isEmpty ||
            name == '.' ||
            name == '..' ||
            name.startsWith('.lanchat-upload-') ||
            sanitizeFileName(name) != name ||
            name.endsWith('.') ||
            name.endsWith(' ') ||
            RegExp(
              r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(name),
      )) {
    throw FormatException('文件夹包含不支持的路径或文件名：$relative');
  }
  return parts;
}

class TreeItem {
  final String path;
  final bool directory;
  final int size;
  const TreeItem(this.path, this.directory, this.size);
}

class TreeSummary {
  final int entries;
  final int bytes;
  final int skippedLinks;
  const TreeSummary(this.entries, this.bytes, this.skippedLinks);
  Map<String, dynamic> toJson() => {
    'entries': entries,
    'bytes': bytes,
    'skippedLinks': skippedLinks,
  };
  factory TreeSummary.fromJson(Map<String, dynamic> json) {
    final entries = json['entries'];
    final bytes = json['bytes'];
    final skipped = json['skippedLinks'] ?? 0;
    if (entries is! int ||
        entries < 0 ||
        entries > maxTreeEntries ||
        bytes is! int ||
        bytes < 0 ||
        bytes > FrameWriter.maxPayloadLength * maxTreeEntries ||
        skipped is! int ||
        skipped < 0 ||
        skipped > maxTreeEntries) {
      throw const FormatException('文件夹清单无效或超过限制（最多 10000 项）');
    }
    return TreeSummary(entries, bytes, skipped);
  }
}

class TreePlan {
  final Directory root;
  final List<TreeItem> items;
  final TreeSummary summary;
  const TreePlan(this.root, this.items, this.summary);

  static Future<TreePlan> scan(
    Directory source, {
    void Function()? check,
  }) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('所选文件夹不存在或是符号链接');
    }
    final root = Directory(await source.resolveSymbolicLinks());
    final items = <TreeItem>[];
    var bytes = 0;
    var skipped = 0;
    var inspected = 0;
    Future<void> walk(String relative) async {
      check?.call();
      final dir = relative.isEmpty
          ? root.path
          : await existingTreePath(root, relative, directory: true);
      final children = <FileSystemEntity>[];
      await for (final child in Directory(dir).list(followLinks: false)) {
        check?.call();
        if (++inspected > maxTreeEntries) {
          throw const FormatException('文件夹内容过多，最多支持 10000 项');
        }
        children.add(child);
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in children) {
        check?.call();
        if (p.basename(entity.path).startsWith('.lanchat-upload-')) continue;
        final kind = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (kind == FileSystemEntityType.link) {
          skipped++;
          continue;
        }
        if (kind != FileSystemEntityType.file &&
            kind != FileSystemEntityType.directory) {
          throw FormatException('无法复制此项目：${p.basename(entity.path)}');
        }
        final path = relative.isEmpty
            ? p.basename(entity.path)
            : '$relative/${p.basename(entity.path)}';
        treeSegments(path);
        final isDirectory = kind == FileSystemEntityType.directory;
        final resolved = await existingTreePath(
          root,
          path,
          directory: isDirectory,
        );
        final size = isDirectory ? 0 : await File(resolved).length();
        if (size > FrameWriter.maxPayloadLength) {
          throw FormatException('文件须小于 4 GiB：$path');
        }
        items.add(TreeItem(path, isDirectory, size));
        bytes += size;
        if (isDirectory) await walk(path);
      }
    }

    await walk('');
    return TreePlan(root, items, TreeSummary(items.length, bytes, skipped));
  }
}

Future<String> existingTreePath(
  Directory root,
  String relative, {
  required bool directory,
}) async {
  var current = root.path;
  if (await FileSystemEntity.type(current, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(await root.resolveSymbolicLinks(), current)) {
    throw const FormatException('文件夹已移动或不可读取');
  }
  final parts = treeSegments(relative);
  for (var i = 0; i < parts.length; i++) {
    current = p.join(current, parts[i]);
    final expected = i < parts.length - 1 || directory
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (await FileSystemEntity.type(current, followLinks: false) != expected) {
      throw FormatException('文件已变化或不可访问（不跟随符号链接）：$relative');
    }
  }
  return current;
}

Directory uniqueDirectoryTarget(Directory parent, String name) {
  if (treeSegments(name).length != 1) throw const FormatException('文件夹名称无效');
  var target = Directory(p.join(parent.path, name));
  var index = 1;
  while (FileSystemEntity.typeSync(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    target = Directory(p.join(parent.path, '$name (${index++})'));
  }
  return target;
}

Future<Digest> _digest(File file, void Function()? check) async {
  final result = _Hash();
  final sink = sha256.startChunkedConversion(result);
  try {
    await for (final chunk in file.openRead()) {
      check?.call();
      sink.add(chunk);
    }
  } finally {
    sink.close();
  }
  return result.value!;
}

Future<void> sendTree(
  Socket socket,
  TreePlan plan, {
  required Future<String> Function(TreeItem) resolve,
  void Function()? check,
  TreeProgress? progress,
}) async {
  var sent = 0;
  var completed = 0;
  for (final item in plan.items) {
    check?.call();
    final source = await resolve(item);
    if (item.directory) {
      socket.add(
        FrameWriter.encode({'type': 'tree-directory', 'path': item.path}),
      );
      await socket.flush();
    } else {
      final file = File(source);
      if (await file.length() != item.size) {
        throw FormatException('文件大小发生变化，请重试：${item.path}');
      }
      final hash = await _digest(file, check);
      check?.call();
      // Recheck after hashing in case the selected path was replaced by a link.
      await resolve(item);
      socket.add(
        FrameWriter.encodeHeader({
          'type': 'tree-file',
          'path': item.path,
          'sha256': hash.toString(),
          'size': item.size,
        }, item.size),
      );
      var count = 0;
      await for (final chunk in file.openRead(0, item.size)) {
        check?.call();
        await socket.addStream(Stream.value(chunk));
        count += chunk.length;
        sent += chunk.length;
        progress?.call(plan.summary.bytes == 0 ? 0 : sent / plan.summary.bytes);
      }
      if (count != item.size) throw FormatException('文件读取不完整：${item.path}');
      await socket.flush();
    }
    completed++;
    if (plan.summary.bytes == 0) progress?.call(completed / plan.items.length);
  }
  check?.call();
  socket.add(
    FrameWriter.encode({'type': 'tree-end', ...plan.summary.toJson()}),
  );
  await socket.flush();
  progress?.call(1);
}

/// Receive into a private staging directory. The caller exposes the tree only
/// after this has verified every entry and the final count/byte summary.
Future<void> receiveTree(
  FrameReader reader,
  Directory root,
  TreeSummary summary, {
  void Function()? check,
  TreeProgress? progress,
}) async {
  var count = 0;
  var bytes = 0;
  while (true) {
    check?.call();
    final frame = await reader.readHeader(timeout: treeFrameTimeout);
    final type = frame.header['type'];
    if (type == 'tree-end') {
      final actual = TreeSummary.fromJson(frame.header);
      if (frame.payloadLen != 0 ||
          count != summary.entries ||
          bytes != summary.bytes ||
          actual.entries != count ||
          actual.bytes != bytes ||
          actual.skippedLinks != summary.skippedLinks) {
        throw const FormatException('文件夹传输不完整，请重试');
      }
      check?.call();
      progress?.call(1);
      return;
    }
    if (++count > summary.entries ||
        (type != 'tree-file' && type != 'tree-directory')) {
      throw const FormatException('文件夹传输清单不一致');
    }
    final relative = frame.header['path'] as String? ?? '';
    final parts = treeSegments(relative);
    var parent = root.path;
    // Parent directories must already have arrived. Never traverse a link or
    // create implicit parents from a remote absolute/traversal path.
    for (final part in parts.take(parts.length - 1)) {
      parent = p.join(parent, part);
      if (await FileSystemEntity.type(parent, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw FormatException('文件夹层级无效：$relative');
      }
    }
    final target = p.join(parent, parts.last);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FormatException('文件夹清单存在重复名称：$relative');
    }
    if (type == 'tree-directory') {
      if (frame.payloadLen != 0) throw const FormatException('文件夹帧格式无效');
      await Directory(target).create();
    } else {
      final size = frame.header['size'];
      final expected = frame.header['sha256'] as String? ?? '';
      if (size != frame.payloadLen ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) ||
          bytes + frame.payloadLen > summary.bytes) {
        throw FormatException('文件大小或校验信息无效：$relative');
      }
      final result = _Hash();
      final hash = sha256.startChunkedConversion(result);
      final sink = File(target).openWrite();
      try {
        await for (final chunk in reader.payloadStream(frame.payloadLen)) {
          check?.call();
          await sink.addStream(Stream.value(chunk));
          hash.add(chunk);
          bytes += chunk.length;
          progress?.call(summary.bytes == 0 ? 0 : bytes / summary.bytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
        hash.close();
      }
      if (result.value.toString() != expected) {
        throw FormatException('文件校验失败：$relative');
      }
    }
    if (summary.bytes == 0) progress?.call(count / summary.entries);
  }
}

class _Hash implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
