import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'constants.dart';
import 'store.dart';

/// This device identity + user preferences.
class Config extends ChangeNotifier {
  final File file;
  final String deviceId;
  String nickname;
  String? downloadDir; // null → store.defaultDownloadsDir
  bool autoAccept;
  int tcpPort; // actual bound port (bumped if taken, e.g. 2nd local instance)

  Config._(this.file, this.deviceId, this.nickname, this.downloadDir, this.autoAccept, this.tcpPort);

  static Future<Config> load(File file) async {
    Map<String, dynamic>? j;
    if (file.existsSync()) {
      try {
        j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {}
    }
    final cfg = Config._(
      file,
      (j?['id'] as String?) ?? const Uuid().v4(),
      (j?['nickname'] as String?)?.trim().isEmpty == false
          ? j!['nickname'] as String
          : Platform.localHostname,
      j?['downloadDir'] as String?,
      j?['autoAccept'] as bool? ?? true,
      (j?['tcpPort'] as int?) ?? K.tcpPort,
    );
    await cfg.save();
    return cfg;
  }

  String get platformLabel =>
      Platform.isWindows ? 'windows' : Platform.isMacOS ? 'macos' : 'android';

  Directory effectiveDownloadDir(AppStore store) {
    final d = downloadDir;
    if (d != null && d.isNotEmpty && Directory(d).existsSync()) return Directory(d);
    return store.defaultDownloadsDir;
  }

  Future<void> save() async {
    AppStore.writeAtomic(
      file,
      const JsonEncoder.withIndent('  ').convert({
        'id': deviceId,
        'nickname': nickname,
        'downloadDir': downloadDir,
        'autoAccept': autoAccept,
        'tcpPort': tcpPort,
      }),
    );
  }

  Future<void> update({String? nickname, String? downloadDir, bool? autoAccept, bool downloadDirSet = false}) async {
    if (nickname != null && nickname.trim().isNotEmpty) this.nickname = nickname.trim();
    if (downloadDirSet) this.downloadDir = downloadDir;
    if (autoAccept != null) this.autoAccept = autoAccept;
    await save();
    notifyListeners();
  }
}
