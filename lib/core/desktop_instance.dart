import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';

/// One desktop process per data directory. Named local test instances use
/// separate directories, so their guards and chat data remain independent.
///
/// The OS releases the lock on exit/crash. Never unlink or read the lock file:
/// POSIX record locks belong to the process, and closing another descriptor
/// for the same inode would release them. IPC metadata is a separate file.
class DesktopInstance {
  static const lockFilename = 'desktop-instance.lock';
  static const endpointFilename = 'desktop-instance.json';
  static final Map<String, DesktopInstance> _localOwners = {};
  final Directory directory;
  final RandomAccessFile _lock;
  final ServerSocket _server;
  final String _token;
  final Future<void> Function() onActivate;
  final Set<Socket> _clients = {};
  bool _closed = false;

  DesktopInstance._(
    this.directory,
    this._lock,
    this._server,
    this._token,
    this.onActivate,
  );

  /// Null means the existing process acknowledged activation; the caller must
  /// exit without initializing networking, notifications or other app state.
  static Future<DesktopInstance?> acquire(
    Directory directory, {
    required Future<void> Function() onActivate,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await directory.create(recursive: true);
    directory = Directory(await directory.resolveSymbolicLinks());
    final local = _localOwners[directory.path];
    if (local != null) {
      await local.onActivate();
      return null;
    }
    final clock = Stopwatch()..start();
    while (true) {
      final lock = await File(
        '${directory.path}/$lockFilename',
      ).open(mode: FileMode.append);
      var owned = false;
      try {
        await lock.lock(FileLock.exclusive, 0, 1);
        owned = true;
      } on FileSystemException {
        await lock.close();
      }
      if (owned) {
        ServerSocket? server;
        try {
          server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          final random = Random.secure();
          final token = List.generate(
            32,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          final instance = DesktopInstance._(
            directory,
            lock,
            server,
            token,
            onActivate,
          );
          server.listen(instance._handle, onError: (_) {});
          // Small metadata can be observed mid-write; secondaries retry JSON
          // parsing while the OS lock continues to arbitrate process ownership.
          File('${directory.path}/$endpointFilename').writeAsStringSync(
            jsonEncode({'port': server.port, 'token': token, 'pid': pid}),
            flush: true,
          );
          _localOwners[directory.path] = instance;
          return instance;
        } catch (_) {
          await server?.close();
          await lock.unlock(0, 1);
          await lock.close();
          rethrow;
        }
      }
      if (await _activate(directory)) return null;
      if (clock.elapsed >= timeout) {
        throw const FileSystemException('LanChat 已运行但暂时未响应，请从托盘打开或稍后重试');
      }
      // Covers simultaneous launches, the primary still starting, and an
      // owner crashing between our failed lock attempt and IPC connection.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static Future<String> _line(Socket socket) {
    final result = Completer<String>();
    final buffer = <int>[];
    // Keep the read subscription alive until the response is flushed. Using
    // Stream.first would cancel the socket stream before we write the reply.
    socket.listen(
      (bytes) {
        if (result.isCompleted) return;
        try {
          buffer.addAll(bytes);
          if (buffer.length > 1024) {
            throw const FormatException('Invalid activation request');
          }
          final newline = buffer.indexOf(10);
          if (newline >= 0) {
            result.complete(utf8.decode(buffer.sublist(0, newline)));
          }
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(
            const SocketException('Activation connection closed'),
          );
        }
      },
    );
    return result.future.timeout(const Duration(seconds: 2));
  }

  static Future<bool> _activate(Directory directory) async {
    Socket? socket;
    try {
      final metadata =
          jsonDecode(
                await File(
                  '${directory.path}/$endpointFilename',
                ).readAsString(),
              )
              as Map;
      final port = metadata['port'];
      final token = metadata['token'];
      final owner = metadata['pid'];
      if (port is! int ||
          port < 1 ||
          port > 65535 ||
          token is! String ||
          token.length != 64 ||
          owner is! int) {
        return false;
      }
      // A newly launched process may grant foreground rights to the primary;
      // otherwise Windows can merely flash its taskbar instead of focusing it.
      if (Platform.isWindows && owner > 0 && owner < 0xffffffff) {
        ffi.DynamicLibrary.open(
          'user32.dll',
        ).lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
          'AllowSetForegroundWindow',
        )(owner);
      }
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.write('${jsonEncode({'action': 'activate', 'token': token})}\n');
      await socket.flush();
      return (jsonDecode(await _line(socket)) as Map)['ok'] == true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _handle(Socket socket) async {
    _clients.add(socket);
    try {
      final request = jsonDecode(await _line(socket)) as Map;
      final allowed =
          !_closed &&
          request['token'] == _token &&
          request['action'] == 'activate';
      if (allowed) await onActivate();
      socket.write('${jsonEncode({'ok': allowed})}\n');
      await socket.flush();
    } catch (_) {
      // Malformed, unauthenticated and closed local connections are ignored.
    } finally {
      _clients.remove(socket);
      socket.destroy();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
    try {
      await File('${directory.path}/$endpointFilename').delete();
    } on FileSystemException {
      /* May already be absent. */
    }
    _localOwners.remove(directory.path);
    await _lock.unlock(0, 1);
    await _lock.close();
  }
}
