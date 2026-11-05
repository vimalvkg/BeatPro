import 'package:flutter/material.dart';

/// BeatPro colours: deep route blue with a marker amber, as in the app icon
/// and the BeatPro screens in Odoo.
class BeatproColors {
  static const navy = Color(0xFF184878);
  static const ink = Color(0xFF10243A);
  static const ground = Color(0xFFF4F6F9);
  static const line = Color(0xFFDCE3EB);
  static const lineSoft = Color(0xFFEDF1F5);
  static const muted = Color(0xFF5B6B7C);
  static const blueSoft = Color(0xFFE6EEF7);
  static const onNavy = Color(0xFFC9D8E8);
  static const amber = Color(0xFFF2B233);
  static const amberInk = Color(0xFF7A4F00);
  static const amberSoft = Color(0xFFFFF6E0);
  static const success = Color(0xFF1F6B45);
  static const successDot = Color(0xFF2E8B57);
  static const successSoft = Color(0xFFE3F2EA);
  static const warning = Color(0xFFB26A00);
  static const danger = Color(0xFF8C1D18);
  static const dangerSoft = Color(0xFFFBE9E7);
}

const _font = 'Manrope';

ThemeData beatproTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: BeatproColors.navy,
    brightness: brightness,
    primary: light ? BeatproColors.navy : const Color(0xFF9CC4F0),
    secondary: BeatproColors.amber,
    surface: light ? Colors.white : null,
    onSurface: light ? BeatproColors.ink : null,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: _font);
  final text = base.textTheme.apply(fontFamily: _font, bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
  return base.copyWith(
    scaffoldBackgroundColor: light ? BeatproColors.ground : null,
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleTextStyle: text.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
      shape: Border(bottom: BorderSide(color: light ? BeatproColors.line : scheme.outlineVariant)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: light ? BeatproColors.line : scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: light ? BeatproColors.line : scheme.outlineVariant),
        textStyle: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: light ? BeatproColors.line : scheme.outlineVariant),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      titleTextStyle: TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface),
      subtitleTextStyle: TextStyle(fontFamily: _font, fontSize: 13, color: light ? BeatproColors.muted : null),
      leadingAndTrailingTextStyle: TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: light ? BeatproColors.blueSoft : null,
      labelTextStyle: WidgetStatePropertyAll(const TextStyle(fontFamily: _font, fontSize: 12, fontWeight: FontWeight.w700)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(textStyle: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
    ),
  );
}
