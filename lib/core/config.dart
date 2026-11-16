import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'constants.dart';
import 'store.dart';

enum AppAppearance { system, light, dark }

enum AppAccent { ocean, forest, violet, amber }

/// This device identity + user preferences.
class Config extends ChangeNotifier {
  final File file;
  final String deviceId;
  String nickname;
  String? downloadDir; // null → store.defaultDownloadsDir
  bool autoAccept;
  bool notifyNewMessages;
  bool flashTrayOnMessage;
  AppAppearance appearance;
  AppAccent accent;
  int tcpPort; // actual bound port (bumped if taken, e.g. 2nd local instance)

  Config._(
    this.file,
    this.deviceId,
    this.nickname,
    this.downloadDir,
    this.autoAccept,
    this.tcpPort, {
    this.appearance = AppAppearance.system,
    this.accent = AppAccent.ocean,
    this.notifyNewMessages = true,
    this.flashTrayOnMessage = true,
  });

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
      notifyNewMessages: j?['notifyNewMessages'] as bool? ?? true,
      flashTrayOnMessage: j?['flashTrayOnMessage'] as bool? ?? true,
      appearance: AppAppearance.values.firstWhere(
        (v) => v.name == j?['appearance'],
        orElse: () => AppAppearance.system,
      ),
      accent: AppAccent.values.firstWhere(
        (v) => v.name == j?['accent'],
        orElse: () => AppAccent.ocean,
      ),
    );
    // Normalization save only; a transient lock (AV scan, low-integrity
    // sandbox) must not abort main() and leave a windowless zombie process.
    try {
      await cfg.save();
    } catch (_) {}
    return cfg;
  }

  String get platformLabel => Platform.isWindows
      ? 'windows'
      : Platform.isMacOS
      ? 'macos'
      : 'android';

  Directory effectiveDownloadDir(AppStore store) {
    final d = downloadDir;
    if (d != null && d.isNotEmpty && Directory(d).existsSync()) {
      return Directory(d);
    }
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
        'notifyNewMessages': notifyNewMessages,
        'flashTrayOnMessage': flashTrayOnMessage,
        'tcpPort': tcpPort,
        'appearance': appearance.name,
        'accent': accent.name,
      }),
    );
  }

  Future<void> update({
    String? nickname,
    String? downloadDir,
    bool? autoAccept,
    bool? notifyNewMessages,
    bool? flashTrayOnMessage,
    bool downloadDirSet = false,
    AppAppearance? appearance,
    AppAccent? accent,
  }) async {
    if (nickname != null && nickname.trim().isNotEmpty) {
      this.nickname = nickname.trim();
    }
    if (downloadDirSet) this.downloadDir = downloadDir;
    if (autoAccept != null) this.autoAccept = autoAccept;
    if (notifyNewMessages != null) this.notifyNewMessages = notifyNewMessages;
    if (flashTrayOnMessage != null) {
      this.flashTrayOnMessage = flashTrayOnMessage;
    }
    if (appearance != null) this.appearance = appearance;
    if (accent != null) this.accent = accent;
    await save();
    notifyListeners();
  }
}
