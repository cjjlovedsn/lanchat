import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lanchat/state/transfers_model.dart';
import 'package:lanchat/ui/widgets/update_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/core/app_updates.dart';
import 'package:lanchat/core/store.dart';

// Remap official HTTPS URLs onto a local HTTP fixture server, preserving the
// production allowlist and checksum checks without using the public Internet.
class _RealHttp extends HttpOverrides {}

class _LocalClient implements HttpClient {
  final HttpClient inner = _RealHttp().createHttpClient(null);
  final Uri base;
  _LocalClient(this.base);
  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      inner.getUrl(base.replace(path: uri.path));
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  set findProxy(String Function(Uri url)? value) => inner.findProxy = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> metadata(
  List<int> data, {
  String tag = 'v1.0.10',
  String? digest,
  bool versioned = false,
}) => {
  'tag_name': tag,
  'body': 'Test release notes',
  'draft': false,
  'prerelease': false,
  'assets': [
    for (final name in [
      'lanchat-setup${versioned ? '-${tag.substring(1)}' : ''}.exe',
      'lanchat-macos${versioned ? '-${tag.substring(1)}' : ''}.dmg',
      'lanchat-android${versioned ? '-${tag.substring(1)}' : ''}.apk',
    ])
      {
        'name': name,
        'size': data.length,
        'digest': 'sha256:${digest ?? sha256.convert(data)}',
        'browser_download_url':
            'https://github.com/cjjlovedsn/lanchat/releases/download/$tag/$name',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bytes = [1, 2, 3, 4, 5, 6, 7, 8];
  late Directory temp;
  late AppStore store;
  late HttpServer server;
  late AppUpdates updates;
  late Map<String, dynamic> response;
  var metadataRequests = 0;
  var assetRequests = 0;
  var status = 200;
  var corrupt = false;
  var throttle = false;
  Completer<void>? downloadStarted;
  Completer<void>? finishDownload;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lanchat_updates_');
    store = await AppStore.open(temp);
    response = metadata(bytes);
    metadataRequests = 0;
    assetRequests = 0;
    status = 200;
    corrupt = false;
    throttle = false;
    downloadStarted = null;
    finishDownload = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path.endsWith('/latest')) {
          metadataRequests++;
          request.response.statusCode = status;
          request.response.write(jsonEncode(response));
        } else {
          assetRequests++;
          request.response.contentLength = bytes.length;
          final data = corrupt ? List.filled(bytes.length, 0) : bytes;
          if (throttle) {
            request.response.add(data.take(2).toList());
            await request.response.flush();
            downloadStarted?.complete();
            await finishDownload?.future;
            request.response.add(data.skip(2).toList());
          } else {
            request.response.add(data);
          }
        }
        await request.response.close();
      } catch (_) {
        /* Expected on cancellation. */
      }
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    updates = AppUpdates(
      store: store,
      currentVersion: '1.0.9',
      platform: 'windows',
      clientFactory: () => _LocalClient(base),
    );
  });
  tearDown(() async {
    updates.dispose();
    if (finishDownload != null && !finishDownload!.isCompleted) {
      finishDownload!.complete();
    }
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  testWidgets('update prompt fits a phone and closing it never downloads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => updates.check());
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppUpdates>.value(value: updates),
          ChangeNotifierProvider<TransfersModel>(
            create: (_) => TransfersModel(),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(context),
                child: const Text('检查'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v1.0.10'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('此版本不再提示更新'));
    await tester.tap(find.text('此版本不再提示更新'));
    await tester.pumpAndSettle();
    expect(updates.isReleaseIgnored, isTrue);
    expect(
      store.readJson(
        File('${temp.path}/update-settings.json'),
      )!['ignoredVersions'],
      ['1.0.10'],
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(assetRequests, 0);
  });

  test(
    'compares numeric versions and selects only official stable platform assets',
    () {
      expect(
        AppRelease.parse(metadata(bytes), 'macos', '1.0.9')!.filename,
        'lanchat-macos.dmg',
      );
      expect(
        AppRelease.parse(metadata(bytes), 'android', '1.0.9')!.filename,
        'lanchat-android.apk',
      );
      expect(AppRelease.parse(metadata(bytes), 'windows', '1.0.10'), isNull);
      expect(AppRelease.parse(metadata(bytes), 'windows', '1.0.11'), isNull);
      expect(
        AppRelease.parse(
          metadata(bytes, tag: 'v2.0.0-beta.1'),
          'windows',
          '1.0.9',
        ),
        isNull,
      );
      expect(
        AppRelease.parse(metadata(bytes)..['draft'] = true, 'windows', '1.0.9'),
        isNull,
      );
      final invalid = metadata(bytes);
      (invalid['assets'] as List).first['browser_download_url'] =
          'https://evil.example/lanchat-setup.exe';
      expect(
        () => AppRelease.parse(invalid, 'windows', '1.0.9'),
        throwsFormatException,
      );
      expect(
        () => AppRelease.parse(
          metadata(bytes, digest: 'missing'),
          'windows',
          '1.0.9',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'prefers versioned assets on every platform and supports legacy releases',
    () {
      final legacy = metadata(bytes);
      final modern = metadata(bytes, versioned: true);
      modern['assets'] = [
        ...legacy['assets'] as List,
        ...modern['assets'] as List,
      ];
      for (final platform in ['windows', 'macos', 'android']) {
        final selected = AppRelease.parse(modern, platform, '1.0.9')!;
        expect(selected.filename, contains('-1.0.10.'));
        expect(selected.url.pathSegments.last, selected.filename);
        expect(
          AppRelease.parse(legacy, platform, '1.0.9')!.filename,
          isNot(contains('-1.0.10.')),
        );
      }
      final asset = (modern['assets'] as List)[3] as Map;
      asset['browser_download_url'] =
          'https://github.com/cjjlovedsn/lanchat/releases/download/v1.0.10/lanchat-setup-1.0.11.exe';
      expect(
        () => AppRelease.parse(modern, 'windows', '1.0.9'),
        throwsFormatException,
      );
    },
  );

  test('versioned packages download and verify normally', () async {
    response = metadata(bytes, versioned: true);
    await updates.check();
    await updates.download();
    expect(updates.error, isNull);
    expect(updates.downloaded!.path, endsWith('lanchat-setup-1.0.10.exe'));
    expect(updates.downloaded!.readAsBytesSync(), bytes);
  });

  test(
    'ignored version survives restart; manual checks and newer releases still work',
    () async {
      await updates.check(automatic: true);
      await updates.setIgnoreRelease(true);
      expect(updates.shouldPrompt, isFalse);
      updates.dispose();
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      updates = AppUpdates(
        store: store,
        currentVersion: '1.0.9',
        platform: 'windows',
        clientFactory: () => _LocalClient(base),
        now: () => DateTime.now().add(const Duration(hours: 7)),
      )..start();
      await updates.check(automatic: true);
      expect(updates.isReleaseIgnored, isTrue);
      expect(updates.shouldPrompt, isFalse);
      await updates.check();
      expect(updates.release!.version.toString(), '1.0.10');
      expect(updates.shouldPrompt, isFalse);
      expect(assetRequests, 0);
      response = metadata(bytes, tag: 'v1.0.11', versioned: true);
      updates.lastCheck = null;
      await updates.check(automatic: true);
      expect(updates.isReleaseIgnored, isFalse);
      expect(updates.shouldPrompt, isTrue);
    },
  );

  test('unchecking ignored version restores automatic reminders', () async {
    await updates.check();
    await updates.setIgnoreRelease(true);
    await updates.setIgnoreRelease(false);
    updates.lastCheck = null;
    await updates.check(automatic: true);
    expect(updates.shouldPrompt, isTrue);
    expect(updates.isReleaseIgnored, isFalse);
  });

  test('failed preference save does not silently ignore a release', () async {
    await updates.check(automatic: true);
    Directory('${temp.path}/update-settings.json.tmp').createSync();
    await updates.setIgnoreRelease(true);
    expect(updates.error, contains('无法保存'));
    expect(updates.isReleaseIgnored, isFalse);
    expect(updates.shouldPrompt, isTrue);
  });

  test(
    'automatic checks throttle and never download; manual checks can retry',
    () async {
      await updates.check(automatic: true);
      expect(updates.release!.version.toString(), '1.0.10');
      expect(updates.shouldPrompt, isTrue);
      expect(assetRequests, 0);
      await updates.check(automatic: true);
      expect(metadataRequests, 1);
      await updates.check();
      expect(metadataRequests, 2);
      expect(updates.shouldPrompt, isFalse);
      await updates.setAutoCheck(false);
      await updates.check(automatic: true);
      expect(metadataRequests, 2);
      final saved = store.readJson(File('${temp.path}/update-settings.json'))!;
      expect(saved['autoCheck'], false);
    },
  );

  test(
    'valid download is verified; tampered bytes cannot reach installer',
    () async {
      await updates.check();
      await updates.download();
      expect(updates.error, isNull);
      expect(updates.downloaded!.readAsBytesSync(), bytes);
      expect(File('${updates.downloaded!.path}.part').existsSync(), isFalse);
      updates.downloaded!.writeAsBytesSync([9, 9, 9, 9, 9, 9, 9, 9]);
      expect(await updates.install(), false);
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('已变化'));
    },
  );

  test(
    'checksum mismatch discards partial download and allows retry',
    () async {
      await updates.check();
      corrupt = true;
      await updates.download();
      expect(updates.error, contains('校验失败'));
      expect(updates.downloaded, isNull);
      expect(Directory('${temp.path}/updates').listSync(), isEmpty);
      corrupt = false;
      await updates.download();
      expect(updates.error, isNull);
      expect(updates.downloaded, isNotNull);
    },
  );

  test(
    'cancelled download never opens installer and removes partial bytes',
    () async {
      await updates.check();
      throttle = true;
      downloadStarted = Completer<void>();
      finishDownload = Completer<void>();
      final pending = updates.download();
      await downloadStarted!.future.timeout(const Duration(seconds: 5));
      updates.cancelDownload();
      finishDownload!.complete();
      await pending;
      expect(updates.downloading, false);
      expect(updates.downloaded, isNull);
      expect(updates.error, isNull);
      expect(Directory('${temp.path}/updates').listSync(), isEmpty);
    },
  );

  test('rate limits are reported without breaking future checks', () async {
    status = 403;
    await updates.check();
    expect(updates.error, contains('过于频繁'));
    expect(updates.checking, false);
    status = 200;
    await updates.check();
    expect(updates.error, isNull);
    expect(updates.release, isNotNull);
  });

  test(
    'native signature mismatch is explained without discarding downloaded APK',
    () async {
      await updates.check();
      await updates.download();
      const channel = MethodChannel('lanchat/updater');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'SIGNATURE_MISMATCH'),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await updates.install(), false);
      expect(updates.error, contains('签名不同'));
      expect(updates.downloaded, isNotNull);
    },
  );
}
