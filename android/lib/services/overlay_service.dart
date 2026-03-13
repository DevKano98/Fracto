// ========== FILE: lib/services/overlay_service.dart ==========
//
// Manages the Fracta floating bubble overlay.
// Handles permissions, lifecycle, messaging, and persistence.

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OverlayService {
  static const String _bubbleEnabledKey = "fracta_bubble_enabled";

  static SharedPreferences? _prefs;

  static Future<SharedPreferences> get _prefsInstance async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// ─────────────────────────────────────────────
  /// Permission Handling
  /// ─────────────────────────────────────────────

  static Future<bool> requestPermission() async {
    try {
      final granted = await FlutterOverlayWindow.isPermissionGranted();

      if (granted) return true;

      await FlutterOverlayWindow.requestPermission();

      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> get hasPermission async {
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// ─────────────────────────────────────────────
  /// Overlay Visibility
  /// ─────────────────────────────────────────────

  static Future<bool> get isBubbleVisible async {
    try {
      return await FlutterOverlayWindow.isActive();
    } catch (_) {
      return false;
    }
  }

  /// ─────────────────────────────────────────────
  /// Show Floating Bubble
  /// ─────────────────────────────────────────────

  static Future<bool> showBubble() async {
    try {
      final permission = await requestPermission();

      if (!permission) return false;

      final alreadyActive = await FlutterOverlayWindow.isActive();

      if (alreadyActive) return true;

      await FlutterOverlayWindow.showOverlay(
        height: 70,
        width: 70,
        alignment: OverlayAlignment.centerRight,
        flag: OverlayFlag.defaultFlag,
        enableDrag: true,
        positionGravity: PositionGravity.auto,
        overlayTitle: "Fracta",
        overlayContent: "Tap to fact-check",
      );

      await _setBubbleEnabled(true);

      return true;
    } catch (_) {
      return false;
    }
  }

  /// ─────────────────────────────────────────────
  /// Hide Floating Bubble
  /// ─────────────────────────────────────────────

  static Future<void> hideBubble() async {
    try {
      final active = await FlutterOverlayWindow.isActive();

      if (active) {
        await FlutterOverlayWindow.closeOverlay();
      }

      await _setBubbleEnabled(false);
    } catch (_) {}
  }

  /// ─────────────────────────────────────────────
  /// Overlay Messaging
  /// ─────────────────────────────────────────────

  /// Listen to messages from overlay isolate
  static Stream<Map<String, dynamic>> get messages =>
      FlutterOverlayWindow.overlayListener.map((event) {
        if (event == null) return <String, dynamic>{};
        return Map<String, dynamic>.from(event);
      });

  /// Alias for compatibility with HomeScreen
  static Stream<Map<String, dynamic>> get overlayMessages => messages;

  /// Send message to overlay widget
  static Future<void> send(Map<String, dynamic> data) async {
    try {
      await FlutterOverlayWindow.shareData(data);
    } catch (_) {}
  }

  /// ─────────────────────────────────────────────
  /// Persistence
  /// ─────────────────────────────────────────────

  static Future<void> _setBubbleEnabled(bool enabled) async {
    final prefs = await _prefsInstance;
    await prefs.setBool(_bubbleEnabledKey, enabled);
  }

  static Future<bool> get wasBubbleEnabled async {
    final prefs = await _prefsInstance;
    return prefs.getBool(_bubbleEnabledKey) ?? false;
  }

  /// Restore bubble automatically on app launch
  static Future<void> restoreBubbleIfNeeded() async {
    final enabled = await wasBubbleEnabled;

    if (!enabled) return;

    final active = await FlutterOverlayWindow.isActive();

    if (!active) {
      await showBubble();
    }
  }
}
