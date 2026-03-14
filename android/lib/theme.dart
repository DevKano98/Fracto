// ========== FILE: lib/theme.dart ==========
// Color scheme: white, orange, light gray. Typography: Roboto.

import 'package:flutter/material.dart';

class AppColors {
  // Primary: orange
  static const Color primary = Color(0xFFE65100);       // Material Orange 900
  static const Color primaryDark = Color(0xFFBF360C);  // Darker orange
  // Backgrounds: white and light grays
  static const Color background = Color(0xFFFFFFFF);   // White
  static const Color surface = Color(0xFFFAFAFA);      // Off-white
  static const Color surfaceVariant = Color(0xFFEEEEEE); // Light gray
  static const Color borderLight = Color(0xFFE0E0E0);  // Border gray
  // Text on white/light
  static const Color onBackground = Color(0xFF212121); // Near black
  static const Color onSurface = Color(0xFF757575);    // Gray text
  // Verdict / risk (readable on light)
  static const Color verdictTrue = Color(0xFF2E7D32);   // Green
  static const Color verdictFalse = Color(0xFFC62828);  // Red
  static const Color verdictMisleading = Color(0xFFEF6C00); // Orange
  static const Color verdictUnverified = Color(0xFF757575);  // Gray
  static const Color riskHigh = Color(0xFFC62828);
  static const Color riskMedium = Color(0xFFEF6C00);
  static const Color riskLow = Color(0xFF2E7D32);

  static Color verdictColor(String verdict) {
    switch (verdict.toUpperCase()) {
      case 'TRUE':
        return verdictTrue;
      case 'FALSE':
        return verdictFalse;
      case 'MISLEADING':
        return verdictMisleading;
      default:
        return verdictUnverified;
    }
  }

  static Color riskColor(String level) {
    switch (level.toUpperCase()) {
      case 'HIGH':
        return riskHigh;
      case 'MEDIUM':
        return riskMedium;
      case 'LOW':
        return riskLow;
      default:
        return verdictUnverified;
    }
  }
}

class AppTheme {
  static const String _fontFamily = 'Roboto';

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.primaryDark,
      onSecondary: Colors.white,
      error: AppColors.verdictFalse,
      onError: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.onSurface,
    );

    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: _fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.onBackground),
        titleTextStyle: TextStyle(
          color: AppColors.onBackground,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          fontFamily: _fontFamily,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: _fontFamily,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.verdictFalse, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.verdictFalse, width: 2),
        ),
        hintStyle: const TextStyle(color: AppColors.onSurface, fontFamily: _fontFamily),
        labelStyle: const TextStyle(color: AppColors.onSurface, fontFamily: _fontFamily),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: AppColors.onBackground,
          fontFamily: _fontFamily,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: AppColors.onBackground,
          fontFamily: _fontFamily,
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: AppColors.onBackground,
          fontFamily: _fontFamily,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.normal,
          color: AppColors.onBackground,
          fontFamily: _fontFamily,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: AppColors.onSurface,
          fontFamily: _fontFamily,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppColors.onSurface,
          fontFamily: _fontFamily,
        ),
      ),
      dividerColor: AppColors.borderLight,
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceVariant,
        contentTextStyle: const TextStyle(color: AppColors.onBackground, fontFamily: _fontFamily),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Alias so existing darkTheme references keep working (now light theme).
  static ThemeData get darkTheme => lightTheme;
}
