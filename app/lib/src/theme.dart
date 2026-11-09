import 'package:flutter/material.dart';

/// BeatPro Van Sales colours: maroon with a marker amber, the same as the
/// BeatPro Theme in Odoo.
class BeatproColors {
  static const brand = Color(0xFF7B1C24);
  static const brandDeep = Color(0xFF5A1018);
  static const red = Color(0xFFB3262E);
  static const ink = Color(0xFF2A1215);
  static const ground = Color(0xFFF8F3F3);
  static const line = Color(0xFFEADCDD);
  static const lineSoft = Color(0xFFF3E8E9);
  static const muted = Color(0xFF6E5A5C);
  static const brandSoft = Color(0xFFFBEDEE);
  static const onBrand = Color(0xFFF1D9DB);
  static const amber = Color(0xFFF2B84B);
  static const amberInk = Color(0xFF7A4F00);
  static const amberSoft = Color(0xFFFFF6E0);
  static const success = Color(0xFF1F6B45);
  static const successDot = Color(0xFF2E8B57);
  static const successSoft = Color(0xFFE3F2EA);
  static const warning = Color(0xFFB26A00);
  static const danger = Color(0xFFA3242B);
  static const dangerSoft = Color(0xFFFBE9E7);

  /// The maroon band behind page headers.
  static const bandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandDeep, brand, red],
    stops: [0, 0.6, 1],
  );
}

const _font = 'Manrope';

/// Arabic letters aren't in Manrope; they come from Noto Sans Arabic.
const _fallback = ['NotoSansArabic'];

ThemeData beatproTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: BeatproColors.brand,
    brightness: brightness,
    primary: light ? BeatproColors.brand : const Color(0xFFF0A6AD),
    secondary: BeatproColors.amber,
    surface: light ? Colors.white : null,
    onSurface: light ? BeatproColors.ink : null,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: _font, fontFamilyFallback: _fallback);
  final text = base.textTheme.apply(fontFamily: _font, fontFamilyFallback: _fallback, bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
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
        textStyle: const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: light ? BeatproColors.line : scheme.outlineVariant),
        textStyle: const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontSize: 15, fontWeight: FontWeight.w700),
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
      titleTextStyle: TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface),
      subtitleTextStyle: TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontSize: 13, color: light ? BeatproColors.muted : null),
      leadingAndTrailingTextStyle: TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontSize: 15, fontWeight: FontWeight.w800, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: light ? BeatproColors.brandSoft : null,
      labelTextStyle: WidgetStatePropertyAll(const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontSize: 12, fontWeight: FontWeight.w700)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(textStyle: const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontWeight: FontWeight.w700)),
    ),
  );
}
