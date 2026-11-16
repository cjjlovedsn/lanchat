import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../app_theme.dart';

Future<void> showAppearanceDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => const _AppearanceDialog(),
);

class _AppearanceDialog extends StatelessWidget {
  const _AppearanceDialog();

  @override
  Widget build(BuildContext context) {
    final config = context.watch<Config>();
    final scheme = Theme.of(context).colorScheme;
    Future<void> update({AppAppearance? appearance, AppAccent? accent}) async {
      try {
        await config.update(appearance: appearance, accent: accent);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('外观设置保存失败，请重试')));
        }
      }
    }

    return AlertDialog(
      title: const Text('外观与主题'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择喜欢的配色与显示模式',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              const Text(
                '显示模式',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final mode in AppAppearance.values)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: mode == AppAppearance.dark ? 0 : 8,
                        ),
                        child: Semantics(
                          selected: config.appearance == mode,
                          button: true,
                          child: InkWell(
                            key: ValueKey('appearance-${mode.name}'),
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => update(appearance: mode),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: config.appearance == mode
                                    ? scheme.primaryContainer
                                    : scheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: config.appearance == mode
                                      ? scheme.primary
                                      : scheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    switch (mode) {
                                      AppAppearance.system =>
                                        Icons.brightness_auto_outlined,
                                      AppAppearance.light =>
                                        Icons.light_mode_outlined,
                                      AppAppearance.dark =>
                                        Icons.dark_mode_outlined,
                                    },
                                    size: 22,
                                    color: config.appearance == mode
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    mode.label,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: config.appearance == mode
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                '主题配色',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              for (var row = 0; row < 2; row++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      for (var col = 0; col < 2; col++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(right: col == 0 ? 10 : 0),
                            child: _AccentTile(
                              accent: AppAccent.values[row * 2 + col],
                              selected:
                                  config.accent ==
                                  AppAccent.values[row * 2 + col],
                              onTap: () => update(
                                accent: AppAccent.values[row * 2 + col],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '即时生效，自动保存',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _AccentTile extends StatelessWidget {
  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;
  const _AccentTile({
    required this.accent,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      button: true,
      label: accent.label,
      child: InkWell(
        key: ValueKey('accent-${accent.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? accent.seed.withValues(alpha: dark ? .18 : .06)
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent.seed : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: accent.seed,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      accent.label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_circle, color: accent.seed, size: 17),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: 52,
                height: 10,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: 66,
                  height: 15,
                  decoration: BoxDecoration(
                    color: accent.seed,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
