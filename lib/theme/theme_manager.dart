import 'package:flutter/material.dart';

class ThemePreset {
  final String name;
  final Color color;

  const ThemePreset({required this.name, required this.color});
}

class ThemeManager {
  static const List<ThemePreset> presets = [
    ThemePreset(name: "Emerald", color: Color(0xFF10B981)),
    ThemePreset(name: "Sapphire", color: Color(0xFF3B82F6)),
    ThemePreset(name: "Ruby", color: Color(0xFFEF4444)),
    ThemePreset(name: "Amethyst", color: Color(0xFF8B5CF6)),
    ThemePreset(name: "Amber", color: Color(0xFFF59E0B)),
  ];

  static final ValueNotifier<Color> accentColorNotifier = ValueNotifier<Color>(const Color(0xFF10B981));

  static Color get accentColor => accentColorNotifier.value;

  static void setAccentColor(Color color) {
    accentColorNotifier.value = color;
  }

  static ThemeData getTheme(Color accent) {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.black,
      primaryColor: accent,
      colorScheme: ColorScheme.dark(
        primary: accent,
        secondary: accent.withValues(alpha: 0.8),
        error: const Color(0xFFEF4444),
        surface: const Color(0xFF0F172A),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0F172A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1E293B), width: 1.2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1E293B), width: 1.2),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: Color(0xFFE2E8F0)),
      ),
    );
  }
}
