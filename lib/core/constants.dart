import 'dart:io';

class K {
  static const String appName = 'LanChat';
  static const int protoVersion = 1;

  /// window/tray/drag-drop are desktop-only; Android takes a different path
  static bool get isDesktop => Platform.isWindows || Platform.isMacOS;


  // discovery
  static const String multicastGroup = '224.0.0.198';
  static const int discoveryPort = 38701;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration offlineAfter = Duration(seconds: 10);

  // transfer
  static const int tcpPort = 38702;
}
