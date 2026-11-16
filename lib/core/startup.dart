import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'store.dart';

/// Current-user login registration. Never changes OS state until explicitly
/// enabled/disabled; the OS registration, rather than a preference, is truth.
class StartupService extends ChangeNotifier {
  static const _channel = MethodChannel('local.lanchat/startup_menu');
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  final String platform;
  final String executable;
  final Directory? home;
  final Future<ProcessResult> Function(String, List<String>) run;
  final bool nativeMenu;
  bool enabled = false;
  bool busy = false;
  String? error;

  StartupService({
    String? platform,
    String? executable,
    Directory? home,
    Future<ProcessResult> Function(String, List<String>)? run,
    this.nativeMenu = true,
  }) : platform = platform ?? Platform.operatingSystem,
       executable = executable ?? Platform.resolvedExecutable,
       home =
           home ??
           (Platform.environment['HOME'] == null
               ? null
               : Directory(Platform.environment['HOME']!)),
       run = run ?? ((exe, args) => Process.run(exe, args));

  bool get supported => platform == 'macos' || platform == 'windows';
  File get agent => File(
    p.join(
      home!.path,
      'Library',
      'LaunchAgents',
      'local.lanchat.startup.plist',
    ),
  );

  Future<void> initialize() async {
    if (!supported) return;
    if (platform == 'macos' && nativeMenu) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'toggle') await setEnabled(!enabled);
      });
    }
    await refresh();
  }

  Future<bool> _read() async {
    if (platform == 'macos') return agent.existsSync();
    final result = await run('reg.exe', ['query', _runKey, '/v', 'LanChat']);
    if (result.exitCode == 0) return true;
    // Distinguish a missing value from registry access/command failures.
    final key = await run('reg.exe', ['query', _runKey]);
    if (key.exitCode != 0) {
      // An absent Run key is normal on a fresh profile. Query its parent.
      final parent = await run('reg.exe', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion',
      ]);
      if (parent.exitCode != 0) throw const FileSystemException('无法读取开机启动设置');
    }
    return false;
  }

  Future<void> refresh() async {
    if (!supported || busy) return;
    try {
      enabled = await _read();
      error = null;
    } catch (_) {
      error = '无法读取开机启动状态，请稍后重试';
    }
    notifyListeners();
    await _syncMenu();
  }

  Future<void> setEnabled(bool value) async {
    if (!supported || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    await _syncMenu();
    try {
      if (platform == 'macos') {
        if (value) {
          agent.parent.createSync(recursive: true);
          final path = const HtmlEscape(
            HtmlEscapeMode.element,
          ).convert(executable);
          AppStore.writeAtomic(agent, '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.lanchat.startup</string>
<key>ProgramArguments</key><array><string>$path</string></array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
''');
        } else if (agent.existsSync()) {
          agent.deleteSync();
        }
      } else {
        final args = value
            ? [
                'add',
                _runKey,
                '/v',
                'LanChat',
                '/t',
                'REG_SZ',
                '/d',
                '"$executable"',
                '/f',
              ]
            : ['delete', _runKey, '/v', 'LanChat', '/f'];
        if (value || await _read()) {
          final result = await run('reg.exe', args);
          if (result.exitCode != 0) {
            throw const FileSystemException('无法修改开机启动设置');
          }
        }
      }
      enabled = await _read();
      if (enabled != value) throw const FileSystemException('开机启动设置未生效');
    } catch (_) {
      error = '无法修改开机启动，请检查系统权限后重试';
    } finally {
      busy = false;
      notifyListeners();
      await _syncMenu();
    }
  }

  Future<void> _syncMenu() async {
    if (platform != 'macos' || !nativeMenu) return;
    try {
      await _channel.invokeMethod<void>('state', {
        'enabled': enabled,
        'busy': busy,
      });
    } on PlatformException {
      // Menu transport failure must not strand an OS operation in busy state.
    } on MissingPluginException {
      /* Unit tests / non-native hosts. */
    }
  }
}
