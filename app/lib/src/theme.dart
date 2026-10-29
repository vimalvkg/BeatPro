import 'package:flutter/material.dart';

/// BeatPro colours: deep route blue with a marker amber, as in the app icon.
class BeatproColors {
  static const navy = Color(0xFF184878);
  static const amber = Color(0xFFF2B233);
  static const success = Color(0xFF2E7D4F);
  static const warning = Color(0xFFB26A00);
  static const danger = Color(0xFFB3261E);
}

ThemeData beatproTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: BeatproColors.navy,
    brightness: brightness,
    primary: brightness == Brightness.light ? BeatproColors.navy : const Color(0xFF9CC4F0),
    secondary: BeatproColors.amber,
  );
  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Roboto',
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        textStyle: const TextStyle(fontFamily: 'Roboto', fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      // Amounts on the right of a row are read at a glance: same size as the title.
      leadingAndTrailingTextStyle: TextStyle(fontFamily: 'Roboto', fontSize: 15, color: scheme.onSurface),
    ),
  );
}
