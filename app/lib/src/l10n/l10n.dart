import 'package:flutter/material.dart' as m;
import 'package:flutter/widgets.dart';

import 'ar.dart';

/// The app's language: `en` or `ar`. Set by the app from the rep's choice in
/// More, or from their language in Odoo.
String appLanguage = 'en';

bool get isArabic => appLanguage == 'ar';

/// Texts with no Arabic yet, collected while [trMisses] is set (tests only).
Set<String>? trMisses;

/// [s] in the app's language. Texts are written in English in the code; the
/// Arabic comes from [translateAr].
String tr(String s) {
  if (!isArabic) {
    if (trMisses != null && s.trim().isNotEmpty) translateAr(s, misses: trMisses);
    return s;
  }
  return translateAr(s);
}

/// The material [m.Text], translated into the app's language as it draws, so
/// screens keep writing `const Text('Collect payment')`.
class Text extends StatelessWidget {
  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  static InlineSpan _span(InlineSpan s) {
    if (s is! TextSpan) return s;
    return TextSpan(
      text: s.text == null ? null : tr(s.text!),
      children: s.children?.map(_span).toList(),
      style: s.style,
      recognizer: s.recognizer,
      semanticsLabel: s.semanticsLabel,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds when the language changes.
    Localizations.maybeLocaleOf(context);
    final args = (
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel == null ? null : tr(semanticsLabel!),
    );
    if (textSpan != null) {
      return m.Text.rich(
        _span(textSpan!),
        style: args.style,
        strutStyle: args.strutStyle,
        textAlign: args.textAlign,
        textDirection: args.textDirection,
        locale: args.locale,
        softWrap: args.softWrap,
        overflow: args.overflow,
        textScaler: args.textScaler,
        maxLines: args.maxLines,
        semanticsLabel: args.semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return m.Text(
      tr(data!),
      style: args.style,
      strutStyle: args.strutStyle,
      textAlign: args.textAlign,
      textDirection: args.textDirection,
      locale: args.locale,
      softWrap: args.softWrap,
      overflow: args.overflow,
      textScaler: args.textScaler,
      maxLines: args.maxLines,
      semanticsLabel: args.semanticsLabel,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
