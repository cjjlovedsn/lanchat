import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/startup.dart';

void main() {
  test(
    'Mac login registration is opt-in, escapes paths and survives restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('lanchat_startup_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = StartupService(
        platform: 'macos',
        home: dir,
        executable:
            '/Applications/LanChat & Friends.app/Contents/MacOS/lanchat',
        nativeMenu: false,
      );
      await service.initialize();
      expect(service.enabled, isFalse);
      expect(service.agent.existsSync(), isFalse);
      await service.setEnabled(true);
      expect(service.error, isNull);
      expect(
        service.agent.readAsStringSync(),
        contains('LanChat &amp; Friends.app'),
      );
      final restarted = StartupService(
        platform: 'macos',
        home: dir,
        nativeMenu: false,
      );
      await restarted.initialize();
      expect(restarted.enabled, isTrue);
      await restarted.setEnabled(false);
      expect(restarted.enabled, isFalse);
      expect(service.agent.existsSync(), isFalse);
    },
  );

  test('Windows quotes the executable and checks command failures', () async {
    var registered = false;
    var failWrites = false;
    final calls = <List<String>>[];
    final service = StartupService(
      platform: 'windows',
      executable: r'C:\Program Files\LanChat\lanchat.exe',
      run: (exe, args) async {
        expect(exe, 'reg.exe');
        calls.add(args);
        if (args.first == 'query') {
          return ProcessResult(
            0,
            args.contains('/v') && !registered ? 1 : 0,
            '',
            '',
          );
        }
        if (failWrites) return ProcessResult(0, 5, '', 'denied');
        registered = args.first == 'add';
        return ProcessResult(0, 0, '', '');
      },
    );
    await service.initialize();
    expect(service.enabled, isFalse);
    await service.setEnabled(true);
    expect(service.enabled, isTrue);
    expect(
      calls.firstWhere((args) => args.first == 'add'),
      contains(r'"C:\Program Files\LanChat\lanchat.exe"'),
    );
    failWrites = true;
    await service.setEnabled(false);
    expect(service.enabled, isTrue);
    expect(service.error, isNotNull);
    expect(service.busy, isFalse);
    failWrites = false;
    await service.setEnabled(false);
    expect(service.enabled, isFalse);
    expect(service.error, isNull);
  });

  test('Mac write failures leave the switch off and report an error', () async {
    final dir = await Directory.systemTemp.createTemp('lanchat_startup_fail_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/Library').writeAsStringSync('not a directory');
    final service = StartupService(
      platform: 'macos',
      home: dir,
      nativeMenu: false,
    );
    await service.setEnabled(true);
    expect(service.enabled, isFalse);
    expect(service.error, isNotNull);
    expect(service.busy, isFalse);
  });
}
