import 'package:flutter/material.dart';

bool ndjoCompact(BuildContext context) => MediaQuery.sizeOf(context).width < 840;

class NdjoColors {
  static const bg = Color(0xFF14110F);
  static const surface = Color(0xFF221C18);
  static const card = Color(0xFF2B231D);
  static const line = Color(0xFF3D3229);
  static const primary = Color(0xFFE85D04);
  static const accent = Color(0xFFF48C06);
  static const text = Color(0xFFFFF8F0);
  static const muted = Color(0xFFC4B5A5);
  static const success = Color(0xFF40916C);
  static const danger = Color(0xFFC1121F);
  static const info = Color(0xFFBC6C25);
}

ThemeData ndjoTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: NdjoColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: NdjoColors.primary,
      secondary: NdjoColors.accent,
      surface: NdjoColors.surface,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: NdjoColors.surface,
      foregroundColor: NdjoColors.text,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: NdjoColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NdjoColors.card,
      isDense: false,
      alignLabelWithHint: true,
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      contentPadding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      labelStyle: const TextStyle(color: NdjoColors.muted, fontSize: 13, height: 1.2),
      hintStyle: const TextStyle(color: Color(0xFF7A6B5C), fontSize: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NdjoColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NdjoColors.line),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
