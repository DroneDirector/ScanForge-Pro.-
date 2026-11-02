import 'package:flutter/material.dart';

class SfColors {
  static const background = Color(0xFF0F1216);
  static const surface = Color(0xFF181D24);
  static const surfaceHigh = Color(0xFF222933);
  static const accent = Color(0xFFFF8A1F); // forge orange
  static const accentSoft = Color(0x33FF8A1F);
  static const good = Color(0xFF3FD18B);
  static const text = Color(0xFFE9EDF2);
  static const textDim = Color(0xFF8B96A5);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: SfColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: SfColors.accent,
    onPrimary: Colors.black,
    surface: SfColors.surface,
    onSurface: SfColors.text,
    surfaceContainerLow: SfColors.surface,
    surfaceContainer: SfColors.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: SfColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: SfColors.background,
      foregroundColor: SfColors.text,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SfColors.accent,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: 'Roboto', fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: SfColors.accent, thumbColor: SfColors.accent),
  );
}
