import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:lanchat/core/desktop_instance.dart';

class _Worker {
  final Process process;
  final StreamIterator<String> output;
  final StringBuffer errors;
  _Worker(this.process, this.output, this.errors);
  static Future<_Worker> start(Directory directory) async {
    final executable = File(Platform.resolvedExecutable);
    // flutter test itself runs in flutter_tester, not the Dart CLI.
    final dart =
        executable.path.endsWith('dart') || executable.path.endsWith('dart.exe')
        ? executable.path
        : p.join(
            executable.parent.parent.parent.parent.path,
            'dart-sdk',
            'bin',
            Platform.isWindows ? 'dart.exe' : 'dart',
          );
    final process = await Process.start(dart, [
      'test/fixtures/desktop-instance/worker.dart',
      directory.path,
    ]);
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    return _Worker(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors,
    );
  }

  Future<String> line() async {
    final more = await output.moveNext().timeout(const Duration(seconds: 15));
    if (!more) throw TestFailure('Worker exited without output: $errors');
    return output.current;
  }

  Future<void> stop() async {
    try {
      process.stdin.writeln('quit');
      await process.stdin.flush();
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await output.cancel();
  }
}

void main() {
  late Directory temp;
  final workers = <_Worker>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lanchat-single-instance-');
  });
  tearDown(() async {
    for (final worker in workers) {
      await worker.stop();
    }
    workers.clear();
    await temp.delete(recursive: true);
  });
  Future<_Worker> start(Directory directory) async {
    final worker = await _Worker.start(directory);
    workers.add(worker);
    return worker;
  }

  test('a second real process activates the primary and exits', () async {
    final first = await start(temp);
    expect(await first.line(), 'PRIMARY');
    final second = await start(temp);
    expect(await second.line(), 'SECONDARY');
    expect(await second.process.exitCode, 0);
    expect(await first.line(), 'ACTIVATED');
  });

  test('simultaneous launches elect exactly one primary', () async {
    final group = await Future.wait(List.generate(4, (_) => start(temp)));
    final states = await Future.wait(group.map((worker) => worker.line()));
    expect(states.where((state) => state == 'PRIMARY'), hasLength(1));
    expect(states.where((state) => state == 'SECONDARY'), hasLength(3));
    final primary = group[states.indexOf('PRIMARY')];
    for (var i = 0; i < 3; i++) {
      expect(await primary.line(), 'ACTIVATED');
    }
  });

  test(
    'normal exit removes endpoint metadata and allows a fresh launch',
    () async {
      final first = await start(temp);
      expect(await first.line(), 'PRIMARY');
      await first.stop();
      workers.remove(first);
      expect(
        File('${temp.path}/${DesktopInstance.endpointFilename}').existsSync(),
        false,
      );
      expect(
        File('${temp.path}/${DesktopInstance.lockFilename}').existsSync(),
        true,
      );
      final next = await start(temp);
      expect(await next.line(), 'PRIMARY');
    },
  );

  test(
    'a crash releases the OS lock and stale metadata never blocks restart',
    () async {
      final first = await start(temp);
      expect(await first.line(), 'PRIMARY');
      first.process.kill(ProcessSignal.sigkill);
      await first.process.exitCode;
      expect(
        File('${temp.path}/${DesktopInstance.endpointFilename}').existsSync(),
        true,
      );
      final restarted = await start(temp);
      expect(await restarted.line(), 'PRIMARY');
      final second = await start(temp);
      expect(await second.line(), 'SECONDARY');
      expect(await restarted.line(), 'ACTIVATED');
    },
  );

  test(
    'named local test directories allow isolated instances, but not duplicates of the same instance',
    () async {
      final a = await start(Directory('${temp.path}/lanchat_A'));
      final b = await start(Directory('${temp.path}/lanchat_B'));
      expect(await a.line(), 'PRIMARY');
      expect(await b.line(), 'PRIMARY');
      final duplicate = await start(Directory('${temp.path}/lanchat_A'));
      expect(await duplicate.line(), 'SECONDARY');
      expect(await a.line(), 'ACTIVATED');
    },
  );

  test('wrong local activation tokens cannot request window focus', () async {
    final first = await start(temp);
    expect(await first.line(), 'PRIMARY');
    final metadata =
        jsonDecode(
              await File(
                '${temp.path}/${DesktopInstance.endpointFilename}',
              ).readAsString(),
            )
            as Map;
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      metadata['port'] as int,
    );
    socket.write('${jsonEncode({'action': 'activate', 'token': 'wrong'})}\n');
    await socket.flush();
    final reply = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect((jsonDecode(reply) as Map)['ok'], false);
    socket.destroy();
    final second = await start(temp);
    expect(await second.line(), 'SECONDARY');
    expect(await first.line(), 'ACTIVATED');
  });
}
