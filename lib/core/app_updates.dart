import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'store.dart';
import 'system_proxy.dart';

const updateRepository = 'cjjlovedsn/lanchat';

class AppRelease {
  final Version version;
  final String notes;
  final Uri url;
  final int size;
  final String digest;
  final String filename;
  AppRelease({
    required this.version,
    required this.notes,
    required this.url,
    required this.size,
    required this.digest,
    required this.filename,
  });

  static AppRelease? parse(
    Map<String, dynamic> json,
    String platform,
    String current,
  ) {
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'] as String? ?? '';
    final version = Version.parse(tag.replaceFirst(RegExp(r'^v'), ''));
    if (version.isPreRelease || version <= Version.parse(current)) return null;
    final filename = switch (platform) {
      'windows' => 'lanchat-setup.exe',
      'macos' => 'lanchat-macos.dmg',
      'android' => 'lanchat-android.apk',
      _ => throw const FormatException('当前平台不支持应用内更新'),
    };
    final assets = (json['assets'] as List? ?? []).whereType<Map>();
    final asset = assets.where((a) => a['name'] == filename).firstOrNull;
    if (asset == null) throw const FormatException('新版尚未提供当前平台的安装包，请稍后重试');
    final uri = Uri.parse(asset['browser_download_url'] as String);
    final prefix = '/$updateRepository/releases/download/$tag/';
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(prefix) ||
        uri.pathSegments.last != filename ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('更新包地址不属于官方发布仓库');
    }
    final digest = asset['digest'] as String? ?? '';
    if (!RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('更新包缺少 SHA256 校验信息，暂不能应用内安装');
    }
    final size = asset['size'] as int? ?? 0;
    if (size <= 0 || size > 2 * 1024 * 1024 * 1024) {
      throw const FormatException('更新包大小无效');
    }
    return AppRelease(
      version: version,
      notes: json['body'] as String? ?? '',
      url: uri,
      size: size,
      digest: digest.substring(7).toLowerCase(),
      filename: filename,
    );
  }
}

/// Only metadata is fetched automatically. A download/installer requires the
/// user to press its button. Chat/discovery remain independent of Internet.
class AppUpdates extends ChangeNotifier {
  static const _native = MethodChannel('lanchat/updater');
  final AppStore store;
  final String currentVersion;
  final String platform;
  final HttpClient Function() clientFactory;
  final Uri endpoint;
  final DateTime Function() now;
  bool autoCheck = true;
  bool checking = false;
  bool shouldPrompt = false;
  bool downloading = false;
  bool installing = false;
  double? progress;
  String? error;
  AppRelease? release;
  File? downloaded;
  DateTime? lastCheck;
  HttpClient? _downloadClient;
  Timer? _initial;
  Timer? _periodic;
  bool _cancelled = false;
  bool _disposed = false;

  AppUpdates({
    required this.store,
    required this.currentVersion,
    String? platform,
    HttpClient Function()? clientFactory,
    Uri? endpoint,
    DateTime Function()? now,
  }) : platform = platform ?? Platform.operatingSystem,
       clientFactory = clientFactory ?? HttpClient.new,
       endpoint =
           endpoint ??
           Uri.https(
             'api.github.com',
             '/repos/$updateRepository/releases/latest',
           ),
       now = now ?? DateTime.now;

  bool get supported {
    try {
      if (Version.parse(currentVersion).isPreRelease) return false;
    } on FormatException {
      return false;
    }
    return const ['macos', 'windows', 'android'].contains(platform);
  }

  bool get busy => checking || downloading || installing;
  File get _preferences =>
      File(p.join(store.base.path, 'update-settings.json'));
  Directory get _directory => Directory(p.join(store.base.path, 'updates'));

  void start() {
    final prefs = store.readJson(_preferences);
    autoCheck = prefs?['autoCheck'] as bool? ?? true;
    lastCheck = DateTime.tryParse(prefs?['lastCheck'] as String? ?? '');
    _initial = Timer(const Duration(seconds: 10), () => check(automatic: true));
    _periodic = Timer.periodic(
      const Duration(hours: 6),
      (_) => check(automatic: true),
    );
  }

  Future<void> setAutoCheck(bool value) async {
    final previous = autoCheck;
    autoCheck = value;
    try {
      _save();
      error = null;
    } catch (_) {
      autoCheck = previous;
      error = '无法保存更新检查设置';
    }
    _notify();
  }

  void _save() => AppStore.writeAtomic(
    _preferences,
    jsonEncode({
      'autoCheck': autoCheck,
      'lastCheck': lastCheck?.toIso8601String(),
    }),
  );

  /// Update traffic follows the OS proxy (Dart's HttpClient would otherwise
  /// go direct and time out where GitHub needs a local proxy). Loopback
  /// targets stay direct so local test servers keep working.
  Future<HttpClient> _client() async {
    final client = clientFactory()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'LanChat/$currentVersion';
    final proxy = await systemHttpProxy();
    if (proxy != null) {
      client.findProxy = (uri) => _isLoopback(uri.host) ? 'DIRECT' : 'PROXY $proxy';
    }
    return client;
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';

  Future<void> check({bool automatic = false}) async {
    if (busy || _disposed) return;
    if (!supported) {
      if (!automatic) {
        error = '调试或未知版本不支持应用内更新，请安装正式版';
        _notify();
      }
      return;
    }
    if (automatic &&
        (!autoCheck ||
            (lastCheck != null &&
                now().difference(lastCheck!) < const Duration(hours: 6)))) {
      return;
    }
    checking = true;
    shouldPrompt = false;
    error = null;
    _notify();
    final client = await _client();
    try {
      final req = await client.getUrl(endpoint);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await req.close().timeout(const Duration(seconds: 20));
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const FormatException('检查过于频繁，请稍后重试');
      }
      if (response.statusCode == 404) throw const FormatException('暂未找到正式发布版本');
      if (response.statusCode != 200) {
        throw const FormatException('更新服务暂不可用，请稍后重试');
      }
      var count = 0;
      final bytes = await response
          .timeout(const Duration(seconds: 20))
          .fold<List<int>>([], (all, chunk) {
            count += chunk.length;
            if (count > 2 * 1024 * 1024) throw const FormatException('更新信息过大');
            return all..addAll(chunk);
          });
      final candidate = AppRelease.parse(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        platform,
        currentVersion,
      );
      if (release?.version != candidate?.version) downloaded = null;
      release = candidate;
      shouldPrompt = automatic && candidate != null;
    } on FormatException catch (e) {
      error = e.message;
    } catch (_) {
      error = '无法连接更新服务，请检查网络后重试';
    } finally {
      client.close(force: true);
      lastCheck = now();
      try {
        _save();
      } catch (_) {
        /* Never break LAN chat on a preference write. */
      }
      checking = false;
      _notify();
    }
  }

  Future<void> download() async {
    final update = release;
    if (update == null || busy || _disposed) return;
    downloading = true;
    _cancelled = false;
    progress = 0;
    error = null;
    downloaded = null;
    _notify();
    final client = await _client();
    _downloadClient = client;
    final target = File(
      p.join(_directory.path, '${update.version}-${update.filename}'),
    );
    final part = File('${target.path}.part');
    IOSink? sink;
    try {
      _directory.createSync(recursive: true);
      final req = await client.getUrl(update.url);
      final response = await req.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw const FormatException('下载失败，请稍后重试');
      if (response.contentLength >= 0 &&
          response.contentLength != update.size) {
        throw const FormatException('安装包大小与发布信息不符');
      }
      sink = part.openWrite();
      final result = _DigestSink();
      final hash = sha256.startChunkedConversion(result);
      var count = 0;
      var last = -1.0;
      await sink.addStream(
        response.timeout(const Duration(seconds: 30)).map((chunk) {
          if (_cancelled) throw const FormatException('已取消下载');
          count += chunk.length;
          if (count > update.size) throw const FormatException('下载内容超过预期大小');
          hash.add(chunk);
          progress = count / update.size;
          if (progress! - last >= .01) {
            last = progress!;
            _notify();
          }
          return chunk;
        }),
      );
      await sink.close();
      sink = null;
      hash.close();
      if (_cancelled) throw const FormatException('已取消下载');
      if (count != update.size || result.value.toString() != update.digest) {
        throw const FormatException('安装包校验失败，已丢弃，请重新下载');
      }
      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
      downloaded = target;
      progress = 1;
      // Keep at most the current download. Incomplete downloads never become installers.
      for (final file in _directory.listSync().whereType<File>()) {
        if (file.path != target.path) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
      }
    } on FormatException catch (e) {
      if (!_cancelled) error = e.message;
    } catch (_) {
      if (!_cancelled) error = '下载中断，请检查网络或磁盘空间后重试';
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      client.close(force: true);
      _downloadClient = null;
      downloading = false;
      _notify();
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _downloadClient?.close(force: true);
  }

  /// Returns true only when the old desktop process should exit for replacement.
  Future<bool> install() async {
    final file = downloaded;
    final update = release;
    if (file == null || update == null || busy) return false;
    installing = true;
    error = null;
    _notify();
    try {
      if (await file.length() != update.size ||
          (await sha256.bind(file.openRead()).first).toString() !=
              update.digest) {
        downloaded = null;
        throw const FormatException('下载包已变化，请重新下载');
      }
      if (supported) {
        final result = await _native.invokeMethod<String>('install', {
          'path': file.path,
          'version': update.version.toString(),
        });
        if (result == 'permission') {
          error = '请在系统设置中允许 LanChat 安装应用，返回后再次点击安装';
          return false;
        }
        return platform != 'android' && result == 'launched';
      }
      throw const FormatException('当前平台暂不支持更新');
    } on PlatformException catch (e) {
      error = e.code == 'SIGNATURE_MISMATCH'
          ? '手机上的旧版和新版签名不同，无法覆盖安装。请先备份需要的数据，再卸载旧版并安装此正式版；之后保持使用同一正式签名。'
          : e.message ?? '无法安装更新';
    } on FormatException catch (e) {
      error = e.message;
    } catch (_) {
      error = '无法启动更新安装，请检查权限后重试';
    } finally {
      installing = false;
      _notify();
    }
    return false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _initial?.cancel();
    _periodic?.cancel();
    cancelDownload();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}
