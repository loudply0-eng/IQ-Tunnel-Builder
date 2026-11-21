import 'package:flutter/material.dart';

class AppThemePalette {
  const AppThemePalette({
    required this.id,
    required this.labelAr,
    required this.labelEn,
    required this.color,
  });

  final String id;
  final String labelAr;
  final String labelEn;
  final Color color;
}

const List<AppThemePalette> appThemePalettes = <AppThemePalette>[
  AppThemePalette(id: 'gold', labelAr: 'ذهبي', labelEn: 'Gold', color: Color(0xFFFFB000)),
  AppThemePalette(id: 'blue', labelAr: 'أزرق', labelEn: 'Blue', color: Color(0xFF2196F3)),
  AppThemePalette(id: 'purple', labelAr: 'بنفسجي', labelEn: 'Purple', color: Color(0xFF7C4DFF)),
  AppThemePalette(id: 'green', labelAr: 'أخضر', labelEn: 'Green', color: Color(0xFF00A86B)),
  AppThemePalette(id: 'red', labelAr: 'أحمر', labelEn: 'Red', color: Color(0xFFE53935)),
  AppThemePalette(id: 'teal', labelAr: 'فيروزي', labelEn: 'Teal', color: Color(0xFF009688)),
  AppThemePalette(id: 'pink', labelAr: 'وردي', labelEn: 'Pink', color: Color(0xFFE91E63)),
  AppThemePalette(id: 'orange', labelAr: 'برتقالي', labelEn: 'Orange', color: Color(0xFFFF6D00)),
  AppThemePalette(id: 'indigo', labelAr: 'نيلي', labelEn: 'Indigo', color: Color(0xFF3F51B5)),
  AppThemePalette(id: 'cyan', labelAr: 'سماوي', labelEn: 'Cyan', color: Color(0xFF00ACC1)),
  AppThemePalette(id: 'lime', labelAr: 'ليموني', labelEn: 'Lime', color: Color(0xFF7CB342)),
  AppThemePalette(id: 'grey', labelAr: 'رمادي', labelEn: 'Grey', color: Color(0xFF78909C)),
];

ThemeData buildIqTunnelTheme(Brightness brightness, Color seedColor) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? const Color(0xFF090B10)
        : const Color(0xFFF5F7FB),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: true,
    ),
    dividerColor: scheme.outlineVariant,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.8),
      ),
    ),
  );
}
