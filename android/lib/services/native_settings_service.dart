// ========== FILE: lib/services/native_settings_service.dart ==========
//
// Platform method channel for Android: overlay permission, battery optimization,
// and real-time screen capture when the floating bubble is on.

import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('fracta/native');

class NativeSettingsService {
  /// Open system "Display over other apps" / overlay permission for this app.
  /// Call when user enables the floating bubble and permission is not yet granted.
  static Future<void> openOverlaySettings() async {
    try {
      await _channel.invokeMethod<void>('openOverlaySettings');
    } on PlatformException catch (_) {
      // Ignore if not implemented (e.g. iOS)
    }
  }

  /// Open battery optimization settings so user can disable it for Fracta.
  /// Prevents the system from killing the background assistant / bubble service.
  static Future<void> openBatteryOptimizationSettings() async {
    try {
      await _channel.invokeMethod<void>('openBatteryOptimizationSettings');
    } on PlatformException catch (_) {}
  }

  /// Request per-app battery optimization exemption (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).
  /// Shows a system dialog asking the user to disable battery optimization for Fracta only.
  /// This is more targeted than opening the full battery settings.
  static Future<void> requestBatteryExemption() async {
    try {
      await _channel.invokeMethod<void>('requestBatteryExemption');
    } on PlatformException catch (_) {}
  }

  /// Whether overlay (draw over other apps) permission is granted (Android).
  static Future<bool> canDrawOverlays() async {
    try {
      final result = await _channel.invokeMethod<bool>('canDrawOverlays');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Request screen capture permission (MediaProjection). Shows system dialog.
  /// After user grants, the capture service runs so we can capture when bubble is tapped.
  static Future<void> requestScreenCapturePermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestScreenCapturePermission');
    } on PlatformException catch (_) {}
  }

  /// Capture the current screen (what the user sees). Returns file path of JPEG, or null.
  /// Call when user taps the bubble so we can verify the visible content.
  static Future<String?> captureScreen() async {
    if (!Platform.isAndroid) return null;
    try {
      final path = await _channel.invokeMethod<String>('captureScreen');
      return path;
    } on PlatformException catch (_) {
      return null;
    }
  }

  /// Stop the screen capture service (e.g. when bubble is turned off).
  static Future<void> stopScreenCapture() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopScreenCapture');
    } on PlatformException catch (_) {}
  }

  /// Whether the MediaProjection screen capture is currently alive.
  static Future<bool> isProjectionAlive() async {
    if (!Platform.isAndroid) return false;
    try {
      final alive = await _channel.invokeMethod<bool>('isProjectionAlive');
      return alive ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }
}
