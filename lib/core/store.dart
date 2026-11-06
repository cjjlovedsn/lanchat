import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// All local persistence lives under one directory.
/// `LANCHAT_INSTANCE` env var (or --dart-define=INSTANCE) splits the data dir
/// so two instances can run on the same machine for testing.
class AppStore {
  final Directory base;

  AppStore._(this.base);

  static Future<AppStore> create() async {
    final root = await getApplicationSupportDirectory();
    final inst = Platform.environment['LANCHAT_INSTANCE'] ??
        const String.fromEnvironment('INSTANCE');
    final dir = Directory(p.join(root.path, 'lanchat${inst.isEmpty ? '' : '_$inst'}'));
    return AppStore.open(dir);
  }

  static Future<AppStore> open(Directory dir) async {
    await dir.create(recursive: true);
    return AppStore._(dir);
  }

  File get configFile => File(p.join(base.path, 'config.json'));
  File get stateFile => File(p.join(base.path, 'state.json'));
  File get unreadFile => File(p.join(base.path, 'unread.json'));

  Directory get historyDir => _ensure('history');
  File historyFile(String peerId) =>
      File(p.join(historyDir.path, '$peerId.jsonl'));

  Directory get outboxDir => _ensure('outbox');
  Directory get outboxFilesDir => _ensure(p.join('outbox', 'files'));
  File outboxFile(String peerId) =>
      File(p.join(outboxDir.path, '$peerId.json'));

  Directory get defaultDownloadsDir => _ensure('downloads');

  Directory _ensure(String sub) {
    final d = Directory(p.join(base.path, sub));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Map<String, dynamic>? readJson(File f) {
    try {
      final s = f.readAsStringSync();
      if (s.trim().isEmpty) return null;
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// tmp file + rename, so a crash mid-write can never truncate the original.
  static void writeAtomic(File f, String content) {
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(content, flush: true);
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(f.path);
  }

  void appendHistory(String peerId, Map<String, dynamic> json) {
    historyFile(peerId).writeAsStringSync('${jsonEncode(json)}\n',
        mode: FileMode.append, flush: true);
  }
}
