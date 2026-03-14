// ========== FILE: lib/services/floating_bubble_service.dart ==========
//
// FloatingBubbleService — Ensures the floating bubble activates correctly
// after overlay permission is granted (SYSTEM_ALERT_WINDOW / draw-over-apps).
// - Checks permission via plugin (Android Settings.canDrawOverlays)
// - Opens overlay settings (ACTION_MANAGE_OVERLAY_PERMISSION) when needed
// - Starts background service so bubble stays when app is minimized
// - Draggable bubble, opens assistant overlay, always accessible

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

  /// Request overlay permission. Opens system settings for "Appear on top".
  static Future<bool> requestOverlayPermission() async {
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) return true;
      await FlutterOverlayWindow.requestPermission();
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// Enable the floating bubble: ensure permission, start background service, then show overlay.
  static Future<bool> enableBubble({
    required Future<void> Function() startBackgroundService,
  }) async {
    try {
      final hasPermission = await hasOverlayPermission;
      if (!hasPermission) {
        await _setPendingBubble(true);
        await FlutterOverlayWindow.requestPermission();
        return false;
      }
      await _setPendingBubble(false);
      await startBackgroundService();
      return await OverlayService.showBubble();
    } catch (_) {
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
  /// and bubble was pending, show overlay now.
  static Future<bool> tryShowBubbleAfterResume({
    required Future<void> Function() startBackgroundService,
  }) async {
    final pending = await wasBubbleEnablePending;
    if (!pending) return false;
    final hasPermission = await hasOverlayPermission;
    if (!hasPermission) return false;
    await _setPendingBubble(false);
    return enableBubble(startBackgroundService: startBackgroundService);
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
