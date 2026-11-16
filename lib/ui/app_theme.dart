import 'package:flutter/material.dart';

import '../core/config.dart';

extension AppearanceLabel on AppAppearance {
  String get label => switch (this) {
    AppAppearance.system => '跟随系统',
    AppAppearance.light => '浅色',
    AppAppearance.dark => '深色',
  };
  ThemeMode get mode => switch (this) {
    AppAppearance.system => ThemeMode.system,
    AppAppearance.light => ThemeMode.light,
    AppAppearance.dark => ThemeMode.dark,
  };
}

extension AccentStyle on AppAccent {
  String get label => switch (this) {
    AppAccent.ocean => '晴空蓝',
    AppAccent.forest => '松石绿',
    AppAccent.violet => '暮光紫',
    AppAccent.amber => '暖砂橙',
  };
  Color get seed => switch (this) {
    AppAccent.ocean => const Color(0xFF3269DE),
    AppAccent.forest => const Color(0xFF158274),
    AppAccent.violet => const Color(0xFF8560CF),
    AppAccent.amber => const Color(0xFFA96320),
  };
}

@immutable
class ChatPalette extends ThemeExtension<ChatPalette> {
  final Color background;
  final Color sidebar;
  final Color canvas;
  final Color incoming;
  final Color outgoing;
  final Color onOutgoing;
  const ChatPalette({
    required this.background,
    required this.sidebar,
    required this.canvas,
    required this.incoming,
    required this.outgoing,
    required this.onOutgoing,
  });

  static ChatPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ChatPalette>() ??
        ChatPalette(
          background: theme.colorScheme.surface,
          sidebar: theme.colorScheme.surfaceContainerLow,
          canvas: theme.colorScheme.surface,
          incoming: theme.colorScheme.surfaceContainerHighest,
          outgoing: theme.colorScheme.primary,
          onOutgoing: theme.colorScheme.onPrimary,
        );
  }

  @override
  ChatPalette copyWith({
    Color? background,
    Color? sidebar,
    Color? canvas,
    Color? incoming,
    Color? outgoing,
    Color? onOutgoing,
  }) => ChatPalette(
    background: background ?? this.background,
    sidebar: sidebar ?? this.sidebar,
    canvas: canvas ?? this.canvas,
    incoming: incoming ?? this.incoming,
    outgoing: outgoing ?? this.outgoing,
    onOutgoing: onOutgoing ?? this.onOutgoing,
  );

  @override
  ChatPalette lerp(covariant ChatPalette? other, double t) {
    if (other == null) return this;
    return ChatPalette(
      background: Color.lerp(background, other.background, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      incoming: Color.lerp(incoming, other.incoming, t)!,
      outgoing: Color.lerp(outgoing, other.outgoing, t)!,
      onOutgoing: Color.lerp(onOutgoing, other.onOutgoing, t)!,
    );
  }
}

ThemeData buildAppTheme(AppAccent accent, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent.seed,
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xFF151B25) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF111720)
            : const Color(0xFFF7F9FC),
        surfaceContainerHighest: dark
            ? const Color(0xFF252E3D)
            : const Color(0xFFEBEFF5),
        onSurface: dark ? const Color(0xFFE4EAF3) : const Color(0xFF202B3D),
        onSurfaceVariant: dark
            ? const Color(0xFF9AA9BD)
            : const Color(0xFF738196),
        outlineVariant: dark
            ? const Color(0xFF2B3545)
            : const Color(0xFFDFE6EF),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xFF0B1018)
        : const Color(0xFFEDF2F8),
    extensions: [
      ChatPalette(
        background: dark ? const Color(0xFF0B1018) : const Color(0xFFEDF2F8),
        sidebar: scheme.surfaceContainerLow,
        canvas: dark ? const Color(0xFF101620) : const Color(0xFFF4F7FB),
        incoming: dark ? const Color(0xFF1C2532) : Colors.white,
        outgoing: dark
            ? Color.lerp(accent.seed, const Color(0xFF18202E), .35)!
            : accent.seed,
        onOutgoing: Colors.white,
      ),
    ],
    fontFamily: 'Inter',
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans',
      'sans-serif',
    ],
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .6),
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
