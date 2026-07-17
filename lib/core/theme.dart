import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shape and spacing constants for the "Modern Fluidity" design system.
class AppSpacing {
  AppSpacing._();

  /// Corner radius for buttons and inputs.
  static const double radiusStandard = 8;

  /// Corner radius for cards.
  static const double radiusCard = 16;

  /// Fully rounded — status badges, search bars.
  static const double radiusPill = 9999;

  /// Minimum height for buttons and other tappable controls.
  static const double minTouchTarget = 48;

  /// Base spacing unit that other spacing should be a multiple of.
  static const double unit = 8;

  /// Gap between major sections of a screen.
  static const double sectionGap = 40;
}

/// Colors for the "Modern Fluidity" design system.
class AppColors {
  AppColors._();

  static const primary = Color(0xFF2F5F8D); // Water Blue
  static const onPrimary = Color(0xFFFFFFFF);
  static const secondary = Color(0xFF43636F); // Deep Navy-ish
  static const secondaryContainer = Color(0xFFC6E8F6); // Soft Aqua
  static const tertiary = Color(0xFF446160);
  static const error = Color(0xFFBA1A1A);
  static const errorContainer = Color(0xFFFFDAD6);
  static const onErrorContainer = Color(0xFF93000A);
  static const surface = Color(0xFFF8F9F9); // cool off-white (background)
  static const surfaceContainerLow = Color(0xFFF3F4F4);
  static const surfaceContainerHigh = Color(0xFFE7E8E8);
  static const onSurface = Color(0xFF191C1C);
  static const onSurfaceVariant = Color(0xFF42474F);
  static const outline = Color(0xFF727780);
  static const outlineVariant = Color(0xFFC2C7D0);
}

class AppTheme {
  AppTheme._();

  static const _colorScheme = ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: AppColors.onPrimary,
    secondary: AppColors.secondary,
    secondaryContainer: AppColors.secondaryContainer,
    tertiary: AppColors.tertiary,
    error: AppColors.error,
    errorContainer: AppColors.errorContainer,
    onErrorContainer: AppColors.onErrorContainer,
    surface: AppColors.surface,
    surfaceContainerLow: AppColors.surfaceContainerLow,
    surfaceContainerHigh: AppColors.surfaceContainerHigh,
    onSurface: AppColors.onSurface,
    onSurfaceVariant: AppColors.onSurfaceVariant,
    outline: AppColors.outline,
    outlineVariant: AppColors.outlineVariant,
  );

  static TextTheme _textTheme(TextTheme base) {
    return base.copyWith(
      // headlineLarge spec is 32px/700 desktop, 24px/700 mobile — this is a
      // phone app, so the mobile size is used here.
      headlineLarge: GoogleFonts.inter(
        fontSize: 24,
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w400,
        height: 1.56, // 28px/18px
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 14 * 0.01, // 0.01em
      ),
      labelSmall: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500),
    );
  }

  static ThemeData get lightTheme {
    final base = ThemeData(colorScheme: _colorScheme, useMaterial3: true);
    final textTheme = _textTheme(
      GoogleFonts.interTextTheme(base.textTheme),
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        elevation: 0,
        titleTextStyle: textTheme.headlineMedium?.copyWith(
          color: AppColors.onPrimary,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          minimumSize: const Size(64, AppSpacing.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          ),
          textStyle: textTheme.labelMedium,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.secondary,
          side: const BorderSide(color: AppColors.secondary),
          minimumSize: const Size(64, AppSpacing.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          ),
          textStyle: textTheme.labelMedium,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.secondaryContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          borderSide: BorderSide.none,
        ),
        // "Subtle glow" on focus: InputDecorationTheme has no native
        // box-shadow/glow support, so this is approximated with a visible
        // primary-colored border — a true glow would need a custom
        // Container-wrapped field with boxShadow.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        // Material 3 cards tint toward the primary color by default at
        // elevation — disabled so the card stays a clean white/soft-aqua
        // surface as specified rather than a blue-tinted one.
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.15),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        ),
      ),
    );
  }
}
