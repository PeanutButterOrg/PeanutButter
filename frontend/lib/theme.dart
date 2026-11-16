import 'package:flutter/material.dart';

import 'design/tokens.g.dart';

/// PeanutButter's theme, built from design/tokens.json (lib/design/tokens.g.dart).
/// Peanut amber is the one main action on a screen; blue is focus and links.
class AppTheme {
  /// Focus, links and selection (was the old seed; same blue).
  static const Color seed = PbColors.focus;
  static const Color canvas = PbColors.ground;
  static const Color rt = PbColors.rt;

  static TextTheme _text(Color text, Color muted) => TextTheme(
        displayLarge: PbType.hero.copyWith(color: text),
        displayMedium: PbType.hero.copyWith(color: text, fontSize: 44),
        displaySmall: PbType.h1.copyWith(color: text, fontSize: 38),
        headlineLarge: PbType.h1.copyWith(color: text),
        headlineMedium: PbType.h1.copyWith(color: text, fontSize: 28),
        headlineSmall: PbType.h2.copyWith(color: text, fontSize: 24),
        titleLarge: PbType.h2.copyWith(color: text),
        titleMedium: PbType.title.copyWith(color: text),
        titleSmall: PbType.title.copyWith(color: text, fontSize: 14),
        bodyLarge: PbType.body.copyWith(color: text, fontSize: 16),
        bodyMedium: PbType.body.copyWith(color: text),
        bodySmall: PbType.meta.copyWith(color: muted, fontSize: 12),
        labelLarge: PbType.button.copyWith(color: text),
        labelMedium: PbType.meta.copyWith(color: text),
        labelSmall: PbType.label.copyWith(color: muted),
      );

  static const _pill = StadiumBorder();
  static const _buttonPadding = EdgeInsets.symmetric(horizontal: 20);

  /// Blue ring for keyboard focus, on every button.
  static WidgetStateProperty<BorderSide?> _focusRing(BorderSide? rest) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return const BorderSide(color: PbColors.focus, width: PbSize.focusRing);
        }
        return rest;
      });

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: PbColors.primary,
      onPrimary: PbColors.onPrimary,
      primaryContainer: PbColors.primaryPressed,
      onPrimaryContainer: PbColors.onPrimary,
      secondary: PbColors.focus,
      onSecondary: PbColors.ground,
      secondaryContainer: PbColors.focusSoft,
      onSecondaryContainer: PbColors.text,
      tertiary: PbColors.good,
      onTertiary: PbColors.ground,
      error: PbColors.bad,
      onError: PbColors.ground,
      surface: PbColors.ground,
      onSurface: PbColors.text,
      onSurfaceVariant: PbColors.textMuted,
      surfaceContainerLowest: PbColors.ground,
      surfaceContainerLow: PbColors.surface,
      surfaceContainer: PbColors.surface,
      surfaceContainerHigh: PbColors.surfaceRaised,
      surfaceContainerHighest: PbColors.surfaceRaised,
      outline: PbColors.line,
      outlineVariant: PbColors.line,
      inverseSurface: PbColors.text,
      onInverseSurface: PbColors.ground,
      shadow: Colors.black,
      scrim: Colors.black,
    );
    final text = _text(PbColors.text, PbColors.textMuted);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: PbFonts.body,
      textTheme: text,
      scaffoldBackgroundColor: PbColors.ground,
      canvasColor: PbColors.ground,
      dividerColor: PbColors.line,
      focusColor: PbColors.focus.withValues(alpha: 0.22),
      hoverColor: Colors.white.withValues(alpha: 0.06),
      appBarTheme: AppBarTheme(
        backgroundColor: PbColors.ground,
        foregroundColor: PbColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: PbType.h2.copyWith(color: PbColors.text),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return PbColors.primary.withValues(alpha: 0.4);
            if (states.contains(WidgetState.pressed)) return PbColors.primaryPressed;
            return PbColors.primary;
          }),
          foregroundColor: const WidgetStatePropertyAll(PbColors.onPrimary),
          textStyle: const WidgetStatePropertyAll(PbType.button),
          shape: const WidgetStatePropertyAll(_pill),
          padding: const WidgetStatePropertyAll(_buttonPadding),
          minimumSize: const WidgetStatePropertyAll(Size(0, PbSize.buttonHeightDesktop)),
          side: _focusRing(null),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.08)),
          foregroundColor: const WidgetStatePropertyAll(PbColors.text),
          textStyle: const WidgetStatePropertyAll(PbType.button),
          shape: const WidgetStatePropertyAll(_pill),
          padding: const WidgetStatePropertyAll(_buttonPadding),
          minimumSize: const WidgetStatePropertyAll(Size(0, PbSize.buttonHeightDesktop)),
          side: _focusRing(BorderSide(color: Colors.white.withValues(alpha: 0.18))),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(PbColors.text),
          textStyle: const WidgetStatePropertyAll(PbType.button),
          shape: const WidgetStatePropertyAll(_pill),
          padding: const WidgetStatePropertyAll(_buttonPadding),
          side: _focusRing(null),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withValues(alpha: 0.06),
        selectedColor: PbColors.primary,
        secondarySelectedColor: PbColors.primary,
        labelStyle: PbType.button.copyWith(fontSize: 13, color: PbColors.text),
        secondaryLabelStyle: PbType.button.copyWith(fontSize: 13, color: PbColors.onPrimary),
        side: const BorderSide(color: PbColors.line),
        shape: _pill,
        showCheckmark: false,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? PbColors.onPrimary : PbColors.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? PbColors.primary : PbColors.surfaceRaised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.transparent : PbColors.line,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: PbColors.primary),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF23252E),
        contentTextStyle: PbType.button.copyWith(color: PbColors.text),
        actionTextColor: PbColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: _pill,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: PbColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(PbRadius.panel))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: PbColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PbRadius.panel),
          side: const BorderSide(color: PbColors.line),
        ),
        textStyle: PbType.body.copyWith(color: PbColors.text),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(PbColors.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PbRadius.panel),
              side: const BorderSide(color: PbColors.line),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: PbColors.surfaceRaised,
        hintStyle: PbType.body.copyWith(color: PbColors.textFaint),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(PbRadius.card), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PbRadius.card),
          borderSide: const BorderSide(color: PbColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PbRadius.card),
          borderSide: const BorderSide(color: PbColors.focus, width: 2),
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
      fontFamily: PbFonts.body,
      textTheme: _text(scheme.onSurface, scheme.onSurfaceVariant),
      // Keep splash / empty router frames off pure white even in light mode.
      scaffoldBackgroundColor: scheme.surface,
      filledButtonTheme: const FilledButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(_pill),
          textStyle: WidgetStatePropertyAll(PbType.button),
        ),
      ),
      outlinedButtonTheme: const OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(_pill),
          textStyle: WidgetStatePropertyAll(PbType.button),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHighest,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PbRadius.panel)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(PbRadius.card), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PbRadius.card),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PbRadius.card),
          borderSide: BorderSide(color: scheme.primary),
        ),
      ),
    );
  }
}

/// Compatibility aliases used by a few screens.
class PtTheme {
  static const Color bg = PbColors.ground;
  static const Color sidebar = PbColors.surface;
  static const Color panel = PbColors.surface;
  static const Color accent = PbColors.focus;
  static const Color muted = PbColors.textMuted;
  static const Color rt = PbColors.rt;
  static const Color completed = PbColors.good;
}
