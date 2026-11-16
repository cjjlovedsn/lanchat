import 'dart:io';

import 'package:meta/meta.dart';

/// OS-level HTTP(S) proxy in "host:port" form, or null when the system is
/// configured for direct connections. The updater needs this: Dart's
/// HttpClient ignores the Windows/macOS system proxy, which breaks
/// api.github.com on networks where GitHub is only reachable via a local
/// proxy (typical for CN users).
Future<String?> systemHttpProxy() async {
  try {
    if (Platform.isWindows) {
      const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final results = await Future.wait([
        Process.run('reg', ['query', key, '/v', 'ProxyEnable'])
            .timeout(const Duration(seconds: 2)),
        Process.run('reg', ['query', key, '/v', 'ProxyServer'])
            .timeout(const Duration(seconds: 2)),
      ]);
      return parseWindowsProxy(
        '${results[0].stdout}',
        '${results[1].stdout}',
      );
    }
    if (Platform.isMacOS) {
      final r = await Process.run('scutil', ['--proxy'])
          .timeout(const Duration(seconds: 2));
      return parseMacProxy('${r.stdout}');
    }
  } catch (_) {
    // Proxy detection must never break an update check.
  }
  return null;
}

@visibleForTesting
String? parseWindowsProxy(String enableOutput, String serverOutput) {
  final enableLine = enableOutput
      .split('\n')
      .firstWhere((l) => l.contains('ProxyEnable'), orElse: () => '');
  if (!enableLine.contains('0x1')) return null;
  final serverLine = serverOutput
      .split('\n')
      .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
  final value =
      serverLine.contains('REG_SZ')
          ? serverLine.split('REG_SZ').last.trim()
          : '';
  if (value.isEmpty || value.contains('://')) return null; // PAC/garbage
  if (value.contains('=')) {
    // Per-protocol form: http=host:port;https=host:port;socks=...
    for (final proto in ['https', 'http']) {
      for (final part in value.split(';')) {
        final kv = part.split('=');
        if (kv.length == 2 && kv.first.trim() == proto) {
          final host = kv.last.trim();
          if (_validHostPort(host)) return host;
        }
      }
    }
    return null;
  }
  return _validHostPort(value) ? value : null;
}

@visibleForTesting
String? parseMacProxy(String scutilOutput) {
  for (final proto in ['HTTPS', 'HTTP']) {
    // scutil prints e.g. "HTTPSEnable : 1", "HTTPSPort : 87".
    if (!RegExp(proto + r'Enable\s*:\s*1').hasMatch(scutilOutput)) continue;
    final port = RegExp(proto + r'Port\s*:\s*(\d+)').firstMatch(scutilOutput);
    final host = RegExp(proto + r'Proxy\s*:\s*(\S+)').firstMatch(scutilOutput);
    if (port != null && host != null) {
      final candidate = '${host.group(1)}:${port.group(1)}';
      if (_validHostPort(candidate)) return candidate;
    }
  }
  return null;
}

bool _validHostPort(String s) => RegExp(r'^[A-Za-z0-9.\-_]+:\d{1,5}$').hasMatch(
  s,
);
