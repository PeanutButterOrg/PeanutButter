import 'package:flutter/material.dart';

/// Original Material 3 catalog theme, without the gold seed.
class AppTheme {
  static const Color seed = Color(0xFF5B9FFF);
  static const Color canvas = Color(0xFF0E0E12);
  static const Color rt = Color(0xFFFA320A);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        ),
      ),
      chipTheme: ChipThemeData(
        selectedColor: scheme.primary.withValues(alpha: 0.28),
        side: BorderSide.none,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF1A1A22),
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Color(0xFF1A1A22)),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF121218),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x22FFFFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: seed),
        ),
      ),
    );
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHighest,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary),
        ),
      ),
    );
  }
}

/// Compatibility aliases used by a few screens.
class PtTheme {
  static const Color bg = AppTheme.canvas;
  static const Color sidebar = Color(0xFF12141A);
  static const Color panel = Color(0xFF1A1A22);
  static const Color accent = AppTheme.seed;
  static const Color muted = Color(0xFF9A9AA8);
  static const Color rt = AppTheme.rt;
}
