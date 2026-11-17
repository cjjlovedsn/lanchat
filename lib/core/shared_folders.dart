import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/peer.dart';
import '../models/shared_folder.dart';
import '../state/transfers_model.dart';
import 'config.dart';
import 'folder_tree.dart';
import 'protocol.dart';
import 'store.dart';
import 'util.dart';

const _timeout = treeFrameTimeout;

/// Shares use the existing TCP port, but require a private per-recipient token.
/// No absolute path is sent to the recipient. Symlinks are never followed.
class SharedFolders extends ChangeNotifier {
  final AppStore store;
  final TransfersModel? transfers;
  final Map<String, FolderGrant> _grants = {};
  SharedFolders(this.store, {this.transfers}) {
    final saved = store.readJson(_file)?['shares'];
    for (final value in saved is List ? saved : const []) {
      try {
        final json = Map<String, dynamic>.from(value as Map);
        final invite = FolderInvite.parse(
          FolderInvite.prefix + jsonEncode(json),
        );
        if (invite == null) continue;
        _grants[invite.id] = FolderGrant(
          invite: invite,
          peerId: json['peerId'] as String,
          root: json['root'] as String,
          writable: json['writable'] == true,
        );
      } catch (_) {}
    }
  }

  File get _file => File(p.join(store.base.path, 'shared-folders.json'));
  List<FolderGrant> forPeer(String peerId) =>
      _grants.values.where((s) => s.peerId == peerId).toList();

  void _save() => AppStore.writeAtomic(
    _file,
    jsonEncode({'shares': _grants.values.map((s) => s.toJson()).toList()}),
  );

  Future<FolderGrant> add(
    String peerId,
    String path, {
    bool writable = false,
  }) async {
    final root = await Directory(path).resolveSymbolicLinks();
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('无法读取所选文件夹');
    }
    // UUID v4 uses a secure random source. Two UUIDs provide an unguessable capability.
    final invite = FolderInvite(
      id: const Uuid().v4(),
      token: '${const Uuid().v4()}${const Uuid().v4()}',
      name: p.basename(root),
    );
    final grant = FolderGrant(
      invite: invite,
      peerId: peerId,
      root: root,
      writable: writable,
    );
    _grants[invite.id] = grant;
    try {
      _save();
    } catch (_) {
      _grants.remove(invite.id);
      rethrow;
    }
    notifyListeners();
    return grant;
  }

  void revoke(String id) {
    final old = _grants.remove(id);
    try {
      _save();
    } catch (_) {
      if (old != null) _grants[id] = old;
      rethrow;
    }
    notifyListeners();
  }

  void setWritable(String id, bool value) {
    final old = _grants[id];
    if (old == null) return;
    _grants[id] = old.withWritable(value);
    try {
      _save();
    } catch (_) {
      _grants[id] = old;
      rethrow;
    }
    notifyListeners();
  }

  FolderGrant _authorize(
    Map<String, dynamic> request,
    String peerId, {
    bool write = false,
  }) {
    final grant = _grants[request['id']];
    if (grant == null ||
        grant.peerId != peerId ||
        grant.invite.token != request['token']) {
      throw const FormatException('共享已取消或无权访问，请让对方重新共享');
    }
    if (write && !grant.writable) throw const FormatException('对方已将此文件夹设为只读');
    return grant;
  }

  static List<String> _segments(String path) {
    if (path.isEmpty) return [];
    final parts = path.split('/');
    if (path.length > 4096 ||
        path.contains('\\') ||
        path.contains(':') ||
        path.contains('\x00') ||
        parts.any(
          (s) =>
              s.isEmpty ||
              s == '.' ||
              s == '..' ||
              s.startsWith('.lanchat-upload-'),
        )) {
      throw const FormatException('文件路径无效');
    }
    return parts;
  }

  Future<String> _resolve(
    FolderGrant grant,
    String relative, {
    bool directory = false,
  }) async {
    var current = grant.root;
    final parts = _segments(relative);
    if (await FileSystemEntity.type(current, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(await Directory(current).resolveSymbolicLinks(), current)) {
      throw const FormatException('共享文件夹已移动或不可访问');
    }
    for (var i = 0; i < parts.length; i++) {
      current = p.join(current, parts[i]);
      final kind = await FileSystemEntity.type(current, followLinks: false);
      final wanted = i < parts.length - 1 || directory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file;
      if (kind != wanted) throw const FormatException('文件不存在或不可访问（不支持符号链接）');
    }
    if (parts.isEmpty && !directory) throw const FormatException('请选择一个文件');
    return current;
  }

  Future<void> handle(
    Socket socket,
    FrameReader reader,
    IncomingHeader frame,
    String peerId,
  ) async {
    Directory? staging;
    var replied = false;
    final progressId = 'shared-${const Uuid().v4()}';
    final request = frame.header;
    try {
      if (frame.payloadLen != 0) throw const FormatException('共享请求格式无效');
      var grant = _authorize(request, peerId);
      final relative = request['path'] as String? ?? '';
      switch (request['action']) {
        case 'list':
          final dir = await _resolve(grant, relative, directory: true);
          final entries = <FolderEntry>[];
          await for (final entity in Directory(dir).list(followLinks: false)) {
            final name = p.basename(entity.path);
            if (name.startsWith('.lanchat-upload-')) continue;
            if (entity is! File && entity is! Directory) continue;
            // Names must also be representable by the cross-platform protocol.
            try {
              _segments(name);
            } on FormatException {
              continue;
            }
            entries.add(
              FolderEntry(
                name: name,
                directory: entity is Directory,
                size: entity is File ? await entity.length() : 0,
              ),
            );
            if (entries.length > 1000) {
              throw const FormatException('此目录文件过多（最多 1000 项），请整理为子文件夹后再访问');
            }
          }
          entries.sort(
            (a, b) => a.directory != b.directory
                ? (a.directory ? -1 : 1)
                : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
          grant = _authorize(request, peerId);
          socket.add(
            FrameWriter.encode({
              'type': 'folder-result',
              'ok': true,
              'writable': grant.writable,
              'entries': entries.map((e) => e.toJson()).toList(),
            }),
          );
        case 'get-tree':
          transfers?.update(progressId, 0);
          final directory = Directory(
            await _resolve(grant, relative, directory: true),
          );
          final plan = await TreePlan.scan(
            directory,
            check: () => _authorize(request, peerId),
          );
          _authorize(request, peerId);
          socket.add(
            FrameWriter.encode({
              'type': 'folder-result',
              'ok': true,
              ...plan.summary.toJson(),
            }),
          );
          await socket.flush();
          replied = true;
          await sendTree(
            socket,
            plan,
            resolve: (item) => _resolve(
              _authorize(request, peerId),
              relative.isEmpty ? item.path : '$relative/${item.path}',
              directory: item.directory,
            ),
            check: () => _authorize(request, peerId),
            progress: (v) => transfers?.update(progressId, v),
          );
        case 'put-tree':
          grant = _authorize(request, peerId, write: true);
          transfers?.update(progressId, 0);
          var parent = await _resolve(grant, relative, directory: true);
          final name = request['name'] as String? ?? '';
          if (treeSegments(name).length != 1) {
            throw const FormatException('文件夹名称无效');
          }
          final summary = TreeSummary.fromJson(request);
          staging = await Directory(parent).createTemp('.lanchat-upload-');
          final tree = await Directory(p.join(staging.path, 'tree')).create();
          socket.add(FrameWriter.encode({'type': 'folder-ready', 'ok': true}));
          await socket.flush();
          await receiveTree(
            reader,
            tree,
            summary,
            check: () => _authorize(request, peerId, write: true),
            progress: (v) => transfers?.update(progressId, v),
          );
          grant = _authorize(request, peerId, write: true);
          parent = await _resolve(grant, relative, directory: true);
          final target = uniqueDirectoryTarget(Directory(parent), name);
          tree.renameSync(target.path);
          socket.add(
            FrameWriter.encode({
              'type': 'folder-result',
              'ok': true,
              'name': p.basename(target.path),
            }),
          );
        case 'get':
          transfers?.update(progressId, 0);
          final file = File(await _resolve(grant, relative));
          final size = await file.length();
          final hash = await sha256.bind(file.openRead()).last;
          _authorize(request, peerId);
          socket.add(
            FrameWriter.encodeHeader({
              'type': 'folder-result',
              'ok': true,
              'sha256': hash.toString(),
            }, size),
          );
          replied = true;
          await for (final chunk in file.openRead(0, size)) {
            _authorize(request, peerId);
            await socket.addStream(Stream.value(chunk));
          }
        case 'put':
          grant = _authorize(request, peerId, write: true);
          transfers?.update(progressId, 0);
          var parent = await _resolve(grant, relative, directory: true);
          final name = request['name'] as String? ?? '';
          if (_segments(name).length != 1 ||
              sanitizeFileName(name) != name ||
              name.endsWith('.') ||
              name.isEmpty) {
            throw const FormatException('文件名无效');
          }
          final size = request['size'] as int? ?? -1;
          final hash = request['sha256'] as String? ?? '';
          if (size < 0 ||
              size > FrameWriter.maxPayloadLength ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
            throw const FormatException('文件大小或校验信息无效（单文件须小于 4 GiB）');
          }
          staging = await Directory(parent).createTemp('.lanchat-upload-');
          final part = File(p.join(staging.path, 'payload'));
          socket.add(FrameWriter.encode({'type': 'folder-ready', 'ok': true}));
          await socket.flush();
          final body = await reader.readHeader(timeout: _timeout);
          if (body.header['type'] != 'folder-body' || body.payloadLen != size) {
            throw const FormatException('文件大小不一致');
          }
          await _receive(
            reader,
            body.payloadLen,
            part,
            hash,
            check: () => _authorize(request, peerId, write: true),
          );
          grant = _authorize(request, peerId, write: true);
          parent = await _resolve(grant, relative, directory: true);
          final target = uniqueFolderTarget(Directory(parent), name);
          // No await between collision check and rename: concurrent uploads cannot overwrite each other.
          part.renameSync(target.path);
          socket.add(
            FrameWriter.encode({
              'type': 'folder-result',
              'ok': true,
              'name': p.basename(target.path),
            }),
          );
        default:
          throw const FormatException('当前客户端不支持此共享操作，请更新双方应用');
      }
      await socket.flush();
    } catch (error) {
      if (!replied) {
        try {
          socket.add(
            FrameWriter.encode({
              'type': 'folder-result',
              'ok': false,
              'reason': error is FormatException
                  ? error.message
                  : '文件访问失败，请检查权限、磁盘空间或网络后重试',
            }),
          );
          await socket.flush();
        } catch (_) {}
      }
    } finally {
      transfers?.remove(progressId);
      try {
        await staging?.delete(recursive: true);
      } catch (_) {}
    }
  }
}

File uniqueFolderTarget(Directory directory, String name) {
  final safe = sanitizeFileName(name);
  var target = File(p.join(directory.path, safe));
  var i = 1;
  while (FileSystemEntity.typeSync(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    target = File(
      p.join(
        directory.path,
        '${p.basenameWithoutExtension(safe)} (${i++})${p.extension(safe)}',
      ),
    );
  }
  return target;
}

Future<void> _receive(
  FrameReader reader,
  int length,
  File target,
  String expected, {
  void Function()? check,
  void Function(double)? progress,
}) async {
  final hash = _DigestSink();
  final converter = sha256.startChunkedConversion(hash);
  final sink = target.openWrite();
  var count = 0;
  try {
    await for (final chunk in reader.payloadStream(length)) {
      check?.call();
      await sink.addStream(Stream.value(chunk));
      converter.add(chunk);
      count += chunk.length;
      progress?.call(length == 0 ? 1 : count / length);
    }
    await sink.flush();
  } finally {
    await sink.close();
    converter.close();
  }
  if (hash.value?.toString() != expected) {
    throw const FormatException('文件校验失败，请重新传输');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) => this.value = value;
  @override
  void close() {}
}

class SharedFolderClient {
  final Config config;
  final Peer peer;
  final FolderInvite invite;
  final TransfersModel? transfers;
  final Set<Socket> _sockets = {};
  int _generation = 0;
  SharedFolderClient({
    required this.config,
    required this.peer,
    required this.invite,
    this.transfers,
  });

  void cancel() {
    _generation++;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }

  Future<T> _request<T>(
    String action,
    String path,
    Future<T> Function(Socket, FrameReader, IncomingHeader) receive, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final address = peer.address;
    final generation = _generation;
    if (address == null) throw const FormatException('对方离线，请连接到同一局域网后重试');
    final socket = await Socket.connect(
      address,
      peer.port,
      timeout: const Duration(seconds: 5),
    );
    if (generation != _generation) {
      socket.destroy();
      throw const FormatException('已取消');
    }
    _sockets.add(socket);
    final reader = FrameReader(socket);
    final progressId = 'shared-${const Uuid().v4()}';
    try {
      if (const ['get', 'put', 'get-tree', 'put-tree'].contains(action)) {
        transfers?.update(progressId, 0);
      }
      socket.add(
        FrameWriter.encode({
          'type': 'hello',
          'id': config.deviceId,
          'name': config.nickname,
          'platform': config.platformLabel,
          'port': config.tcpPort,
        }),
      );
      socket.add(
        FrameWriter.encode({
          'type': 'shared-folder',
          'id': invite.id,
          'token': invite.token,
          'action': action,
          'path': path,
          ...extra,
        }),
      );
      await socket.flush();
      final reply = await reader.readHeader(timeout: _timeout);
      _check(reply);
      return await receive(socket, reader, reply);
    } finally {
      transfers?.remove(progressId);
      _sockets.remove(socket);
      socket.destroy();
      await reader.close();
    }
  }

  static void _check(IncomingHeader frame) {
    if (frame.header['ok'] != true) {
      throw FormatException(
        frame.header['reason'] as String? ?? '对方未提供共享文件夹服务，请确认双方均已更新',
      );
    }
  }

  Future<FolderListing> list(String path) => _request('list', path, (
    _,
    _,
    reply,
  ) async {
    final entries = (reply.header['entries'] as List)
        .map((e) => FolderEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    // A malicious remote must not be able to supply local paths via entry names.
    for (final entry in entries) {
      if (SharedFolders._segments(entry.name).length != 1) {
        throw const FormatException('对方返回了无效的文件名');
      }
    }
    return FolderListing(entries, reply.header['writable'] == true);
  });

  Future<File> download(
    String path,
    Directory destination, {
    void Function(double)? progress,
  }) async {
    Directory? stage;
    try {
      return await _request('get', path, (_, reader, reply) async {
        final hash = reply.header['sha256'] as String? ?? '';
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
          throw const FormatException('缺少文件校验信息');
        }
        stage = await destination.createTemp('.lanchat-download-');
        final part = File(p.join(stage!.path, 'payload'));
        await _receive(
          reader,
          reply.payloadLen,
          part,
          hash,
          progress: progress,
        );
        final target = uniqueFolderTarget(destination, p.posix.basename(path));
        return part.renameSync(target.path);
      });
    } finally {
      try {
        await stage?.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<FolderTransferReport> downloadDirectory(
    String path,
    Directory destination, {
    TreeProgress? progress,
  }) async {
    Directory? stage;
    final generation = _generation;
    void check() {
      if (generation != _generation) throw const FormatException('已取消');
    }

    try {
      return await _request('get-tree', path, (_, reader, reply) async {
        final summary = TreeSummary.fromJson(reply.header);
        stage = await destination.createTemp('.lanchat-download-');
        final tree = await Directory(p.join(stage!.path, 'tree')).create();
        await receiveTree(
          reader,
          tree,
          summary,
          check: check,
          progress: progress,
        );
        check();
        final target = uniqueDirectoryTarget(
          destination,
          path.isEmpty ? invite.name : p.posix.basename(path),
        );
        tree.renameSync(target.path);
        return FolderTransferReport(target.path, summary.skippedLinks);
      });
    } finally {
      try {
        await stage?.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<FolderTransferReport> uploadDirectory(
    String path,
    Directory directory, {
    TreeProgress? progress,
  }) async {
    final generation = _generation;
    void check() {
      if (generation != _generation) throw const FormatException('已取消');
    }

    final name = p.basename(p.normalize(directory.path));
    if (treeSegments(name).length != 1) throw const FormatException('文件夹名称无效');
    final plan = await TreePlan.scan(directory, check: check);
    check();
    return _request('put-tree', path, (socket, reader, ready) async {
      if (ready.header['type'] != 'folder-ready') {
        throw const FormatException('对方未准备好接收文件夹');
      }
      await sendTree(
        socket,
        plan,
        resolve: (item) =>
            existingTreePath(plan.root, item.path, directory: item.directory),
        check: check,
        progress: progress,
      );
      final reply = await reader.readHeader(timeout: _timeout);
      _check(reply);
      return FolderTransferReport(
        reply.header['name'] as String,
        plan.summary.skippedLinks,
      );
    }, {'name': name, ...plan.summary.toJson()});
  }

  Future<String> upload(
    String path,
    File file, {
    void Function(double)? progress,
  }) async {
    final generation = _generation;
    final size = await file.length();
    if (size > FrameWriter.maxPayloadLength) {
      throw const FormatException('单文件须小于 4 GiB');
    }
    final hash = await sha256.bind(file.openRead()).last;
    if (generation != _generation) throw const FormatException('已取消');
    return _request(
      'put',
      path,
      (socket, reader, ready) async {
        if (ready.header['type'] != 'folder-ready') {
          throw const FormatException('对方未准备好接收文件');
        }
        socket.add(FrameWriter.encodeHeader({'type': 'folder-body'}, size));
        var sent = 0;
        await for (final chunk in file.openRead(0, size)) {
          await socket.addStream(Stream.value(chunk));
          sent += chunk.length;
          progress?.call(size == 0 ? 1 : sent / size);
        }
        await socket.flush();
        final reply = await reader.readHeader(timeout: _timeout);
        _check(reply);
        return reply.header['name'] as String;
      },
      {'name': p.basename(file.path), 'size': size, 'sha256': hash.toString()},
    );
  }
}

class FolderTransferReport {
  final String path;
  final int skippedLinks;
  const FolderTransferReport(this.path, this.skippedLinks);
}
