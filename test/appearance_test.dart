import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:lanchat/core/config.dart';
import 'package:lanchat/ui/app_theme.dart';
import 'package:lanchat/ui/widgets/appearance_dialog.dart';

void main() {
  test('legacy preferences migrate and appearance survives restart', () async {
    final dir = await Directory.systemTemp.createTemp('lanchat_appearance_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/config.json')
      ..writeAsStringSync(
        '{"id":"existing-device","nickname":"My Mac","appearance":"unknown","accent":"unknown"}',
      );
    final config = await Config.load(file);
    expect(config.appearance, AppAppearance.system);
    expect(config.accent, AppAccent.ocean);
    await config.update(
      appearance: AppAppearance.dark,
      accent: AppAccent.forest,
    );
    final restored = await Config.load(file);
    expect(restored.deviceId, 'existing-device');
    expect(restored.nickname, 'My Mac');
    expect(restored.appearance, AppAppearance.dark);
    expect(restored.accent, AppAccent.forest);
  });

  test('all light and dark accents keep outgoing text readable', () {
    for (final accent in AppAccent.values) {
      for (final brightness in Brightness.values) {
        final palette = buildAppTheme(
          accent,
          brightness,
        ).extension<ChatPalette>()!;
        final a = palette.outgoing.computeLuminance();
        final b = palette.onOutgoing.computeLuminance();
        expect(
          (max(a, b) + .05) / (min(a, b) + .05),
          greaterThanOrEqualTo(4.5),
          reason: '${accent.name} ${brightness.name}',
        );
      }
    }
  });

  testWidgets('appearance switches live, follows system, and fits a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory dir;
    late Config config;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lanchat_appearance_ui_');
      config = await Config.load(File('${dir.path}/config.json'));
    });
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(config.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<Config>.value(
        value: config,
        child: Consumer<Config>(
          builder: (context, cfg, _) => MaterialApp(
            theme: buildAppTheme(cfg.accent, Brightness.light),
            darkTheme: buildAppTheme(cfg.accent, Brightness.dark),
            themeMode: cfg.appearance.mode,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAppearanceDialog(context),
                  child: const Text('外观'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-dark')));
    await tester.pumpAndSettle();
    expect(config.appearance, AppAppearance.dark);
    expect(
      Theme.of(tester.element(find.text('外观与主题'))).brightness,
      Brightness.dark,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('accent-forest')));
    await tester.tap(find.byKey(const ValueKey('accent-forest')));
    await tester.pumpAndSettle();
    expect(config.accent, AppAccent.forest);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('appearance-system')));
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    await tester.tap(find.byKey(const ValueKey('appearance-system')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('外观与主题'))).brightness,
      Brightness.light,
    );
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('外观与主题'))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
