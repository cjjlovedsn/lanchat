import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/system_proxy.dart';

const windowsEnabled = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
''';

const windowsDisabled = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x0
''';

String windowsServer(String value) => '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyServer    REG_SZ    $value
''';

void main() {
  test('windows static and per-protocol proxies are parsed', () {
    expect(
      parseWindowsProxy(windowsEnabled, windowsServer('127.0.0.1:7892')),
      '127.0.0.1:7892',
    );
    expect(
      parseWindowsProxy(
        windowsEnabled,
        windowsServer('http=127.0.0.1:7891;https=127.0.0.1:7892'),
      ),
      '127.0.0.1:7892',
    );
    expect(
      parseWindowsProxy(windowsEnabled, windowsServer('http=127.0.0.1:7891')),
      '127.0.0.1:7891',
    );
  });

  test('windows rejects disabled, PAC and garbage values', () {
    expect(parseWindowsProxy(windowsDisabled, windowsServer('127.0.0.1:7892')), isNull);
    expect(parseWindowsProxy(windowsEnabled, windowsServer('socks=127.0.0.1:7890')), isNull);
    expect(
      parseWindowsProxy(
        windowsEnabled,
        windowsServer('http://proxy.example/pac.dat'),
      ),
      isNull,
    );
    expect(parseWindowsProxy(windowsEnabled, ''), isNull);
    expect(parseWindowsProxy(windowsEnabled, windowsServer('not a proxy')), isNull);
  });

  test('macos scutil output is parsed with https preferred', () {
    const output = '''
<dictionary> {
  HTTPEnable : 0
  HTTPProxy : 127.0.0.1
  HTTPPort : 8888
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7892
}
''';
    expect(parseMacProxy(output), '127.0.0.1:7892');
    const httpOnly = '''
<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 8888
  HTTPSEnable : 0
}
''';
    expect(parseMacProxy(httpOnly), '127.0.0.1:8888');
    const direct = '''
<dictionary> {
  HTTPEnable : 0
  HTTPSEnable : 0
}
''';
    expect(parseMacProxy(direct), isNull);
  });
}
