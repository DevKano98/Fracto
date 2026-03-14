// ========== FILE: lib/services/floating_bubble_service.dart ==========
//
// FloatingBubbleService — Ensures the floating bubble activates correctly
// after overlay permission is granted (SYSTEM_ALERT_WINDOW / draw-over-apps).
// - Checks permission via plugin (Android Settings.canDrawOverlays)
// - Opens overlay settings via permission_handler when needed
// - Shows overlay first (while app in foreground), then starts background service
// - Draggable bubble, opens assistant overlay, always accessible

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'overlay_service.dart';

class FloatingBubbleService {
  static const String _pendingBubbleKey = "fracta_bubble_pending_enable";

  static SharedPreferences? _prefs;
  static Future<SharedPreferences> get _prefsInstance async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Whether overlay (draw-over-apps) permission is granted.
  static Future<bool> get hasOverlayPermission async {
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// Request overlay permission: open system "Display over other apps" settings.
  /// Use permission_handler so user is taken to the right screen.
  /// Sets pending so when user returns and grants, tryShowBubbleAfterResume can show the bubble.
  static Future<bool> requestOverlayPermission() async {
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) return true;
      await _setPendingBubble(true);
      // Open overlay permission screen (user must enable "Fracta" in the list)
      final status = await Permission.systemAlertWindow.request();
      if (status.isGranted) return true;
      // Plugin fallback in case permission_handler didn't open the right screen
      await FlutterOverlayWindow.requestPermission();
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (e) {
      if (kDebugMode) debugPrint('FloatingBubbleService.requestOverlayPermission: $e');
      return false;
    }
  }

  /// Enable the floating bubble: ensure permission, show overlay first, then start background service.
  /// Showing overlay while app is in foreground avoids timing issues.
  static Future<bool> enableBubble({
    required Future<void> Function() startBackgroundService,
  }) async {
    try {
      final hasPermission = await hasOverlayPermission;
      if (!hasPermission) {
        await _setPendingBubble(true);
        await requestOverlayPermission();
        return false;
      }
      await _setPendingBubble(false);
      // Show overlay first (main app still in foreground), then start background service
      final shown = await OverlayService.showBubble(skipPermissionCheck: true);
      if (shown) await startBackgroundService();
      return shown;
    } catch (e) {
      if (kDebugMode) debugPrint('FloatingBubbleService.enableBubble: $e');
      return false;
    }
  }

  static Future<void> _setPendingBubble(bool pending) async {
    final prefs = await _prefsInstance;
    await prefs.setBool(_pendingBubbleKey, pending);
  }

  static Future<bool> get wasBubbleEnablePending async {
    final prefs = await _prefsInstance;
    return prefs.getBool(_pendingBubbleKey) ?? false;
  }

  /// Call when app resumes (e.g. from overlay settings). If user granted permission
  /// and bubble was pending, show overlay now. Delay slightly so system updates permission state.
  static Future<bool> tryShowBubbleAfterResume({
    required Future<void> Function() startBackgroundService,
  }) async {
    final pending = await wasBubbleEnablePending;
    if (!pending) return false;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final hasPermission = await hasOverlayPermission;
    if (!hasPermission) return false;
    await _setPendingBubble(false);
    final ok = await enableBubble(startBackgroundService: startBackgroundService);
    if (!ok) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return await enableBubble(startBackgroundService: startBackgroundService);
    }
    return true;
  }

  /// Disable the floating bubble.
  static Future<void> disableBubble() async {
    try {
      await _setPendingBubble(false);
      await OverlayService.hideBubble();
    } catch (_) {}
  }

  static Future<bool> get isBubbleVisible async => OverlayService.isBubbleVisible;
}
