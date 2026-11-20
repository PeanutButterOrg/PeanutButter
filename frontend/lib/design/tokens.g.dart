// Generated from design/tokens.json by scripts/gen-design-tokens.py. Do not edit.
// ignore_for_file: constant_identifier_names

import 'package:flutter/painting.dart';

/// PeanutButter's colours (see design/tokens.json for what each is for).
abstract final class PbColors {
  /// Page background, behind everything
  static const Color ground = Color(0xFF0E0E12);
  /// Cards, panels, menus
  static const Color surface = Color(0xFF16171D);
  /// Hovered or selected surface, inputs
  static const Color surfaceRaised = Color(0xFF1E2028);
  /// Hairlines and outlines
  static const Color line = Color(0xFF2A2D37);
  /// Main text
  static const Color text = Color(0xFFF1F3F7);
  /// Secondary text, captions
  static const Color textMuted = Color(0xFFA7ADBB);
  /// Hints, disabled text
  static const Color textFaint = Color(0xFF6E7483);
  /// Peanut amber: the main action (Play, Save) and active chips
  static const Color primary = Color(0xFFE2A456);
  /// Primary while pressed
  static const Color primaryPressed = Color(0xFFC98A3E);
  /// Text and icons on primary
  static const Color onPrimary = Color(0xFF1A1206);
  /// Focus ring (keyboard / remote): soft white, like the text
  static const Color focus = Color(0xFFF1F3F7);
  /// Focused surface tint on TV
  static const Color focusSoft = Color(0xFF3A3D48);
  /// The blue 'Butter' in the logo
  static const Color brand = Color(0xFF5B9FFF);
  /// Healthy, done, on
  static const Color good = Color(0xFF4ADE80);
  /// Weak, attention
  static const Color warn = Color(0xFFFBBF24);
  /// Errors, dead, destructive
  static const Color bad = Color(0xFFF87171);
  /// Rotten Tomatoes red, only on its badge
  static const Color rt = Color(0xFFFA320A);
  /// Top bar once content scrolls under it
  static const Color scrimTop = Color(0xF20E0E12);
  /// Hero fade behind text
  static const Color scrimHero = Color(0xE60E0E12);
}

/// Font families. Bundled with the app.
abstract final class PbFonts {
  static const String display = 'Space Grotesk';
  static const String body = 'Inter';
}

/// Desktop type scale (logical pixels).
abstract final class PbType {
  /// Title name on the hero and title page
  static const TextStyle hero = TextStyle(fontFamily: PbFonts.display, fontSize: 52, fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)], height: 1.0, letterSpacing: -0.5);
  /// Page titles (My List, Explore, Settings)
  static const TextStyle h1 = TextStyle(fontFamily: PbFonts.display, fontSize: 34, fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)], height: 1.1, letterSpacing: -0.3);
  /// Row and section headings
  static const TextStyle h2 = TextStyle(fontFamily: PbFonts.display, fontSize: 22, fontWeight: FontWeight.w600, fontVariations: [FontVariation('wght', 600)], height: 1.2, letterSpacing: 0);
  /// Card titles, list items
  static const TextStyle title = TextStyle(fontFamily: PbFonts.body, fontSize: 16, fontWeight: FontWeight.w600, fontVariations: [FontVariation('wght', 600)], height: 1.3, letterSpacing: 0);
  /// Synopsis, descriptions
  static const TextStyle body = TextStyle(fontFamily: PbFonts.body, fontSize: 14, fontWeight: FontWeight.w400, fontVariations: [FontVariation('wght', 400)], height: 1.5, letterSpacing: 0);
  /// Year, runtime, rating line
  static const TextStyle meta = TextStyle(fontFamily: PbFonts.body, fontSize: 13, fontWeight: FontWeight.w500, fontVariations: [FontVariation('wght', 500)], height: 1.35, letterSpacing: 0);
  /// Uppercase eyebrows and badges
  static const TextStyle label = TextStyle(fontFamily: PbFonts.body, fontSize: 11, fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)], height: 1.2, letterSpacing: 0.8);
  /// Buttons and chips
  static const TextStyle button = TextStyle(fontFamily: PbFonts.body, fontSize: 14, fontWeight: FontWeight.w600, fontVariations: [FontVariation('wght', 600)], height: 1.0, letterSpacing: 0);
}

/// TV type scale, for the same names on a 10-foot screen.
abstract final class PbTypeTv {
  static const TextStyle hero = TextStyle(fontFamily: PbFonts.display, fontSize: 44, fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)], height: 1.0, letterSpacing: -0.5);
  static const TextStyle h1 = TextStyle(fontFamily: PbFonts.display, fontSize: 32, fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)], height: 1.1, letterSpacing: -0.3);
  static const TextStyle h2 = TextStyle(fontFamily: PbFonts.display, fontSize: 24, fontWeight: FontWeight.w600, fontVariations: [FontVariation('wght', 600)], height: 1.2, letterSpacing: 0);
  static const TextStyle title = TextStyle(fontFamily: PbFonts.body, fontSize: 18, fontWeight: FontWeight.w600, fontVariations: [FontVariation('wght', 600)], height: 1.3, letterSpacing: 0);
  static const TextStyle body = TextStyle(fontFamily: PbFonts.body, fontSize: 16, fontWeight: FontWeight.w400, fontVariations: [FontVariation('wght', 400)], height: 1.5, letterSpacing: 0);
  static const TextStyle meta = TextStyle(fontFamily: PbFonts.body, fontSize: 15, fontWeight: FontWeight.w500, fontVariations: [FontVariation('wght', 500)], height: 1.35, letterSpacing: 0);
  static const TextStyle label = TextStyle(fontFamily: PbFonts.body, fontSize: 12, fontWeight: FontWeight.w700, fontVariations: [FontVariation('wght', 700)], height: 1.2, letterSpacing: 0.8);
  static const TextStyle button = TextStyle(fontFamily: PbFonts.body, fontSize: 16, fontWeight: FontWeight.w600, fontVariations: [FontVariation('wght', 600)], height: 1.0, letterSpacing: 0);
}

abstract final class PbSpace {
  static const double xxs = 4.0;
  static const double xs = 8.0;
  static const double sm = 12.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
  static const double gutterDesktop = 36.0;
  static const double gutterTv = 48.0;
}

abstract final class PbRadius {
  static const double badge = 6.0;
  static const double card = 10.0;
  static const double panel = 16.0;
  static const double pill = 999.0;
}

abstract final class PbSize {
  static const double posterWidthDesktop = 150.0;
  static const double posterWidthTv = 132.0;
  static const double wideCardWidthDesktop = 300.0;
  static const double wideCardWidthTv = 268.0;
  static const double buttonHeightDesktop = 38.0;
  static const double buttonHeightTv = 48.0;
  static const double topBarHeightDesktop = 60.0;
  static const double topBarHeightTv = 72.0;
  static const double focusRing = 3.0;
  static const double focusRingOffset = 3.0;
  static const double focusScaleTv = 1.06;
}

/// Animation durations.
abstract final class PbMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 180);
  static const Duration slow = Duration(milliseconds: 280);
}
