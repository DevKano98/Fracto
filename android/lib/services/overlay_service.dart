// ========== FILE: lib/services/overlay_service.dart ==========
//
// Manages the floating Fracta bubble that appears over all other apps.
// When tapped, it opens an overlay quick-capture sheet.
// After verification, the result card appears as an overlay.
//
// Requires: SYSTEM_ALERT_WINDOW permission (draw over other apps)

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OverlayService {
  static const _kBubbleEnabledKey = 'fracta_bubble_enabled';

  /// Request draw-over-apps permission.
  static Future<bool> requestPermission() async {
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted) {
      await FlutterOverlayWindow.requestPermission();
      return await FlutterOverlayWindow.isPermissionGranted();
    }
    return true;
  }

  static Future<bool> get hasPermission =>
      FlutterOverlayWindow.isPermissionGranted();

  /// Show the floating bubble.
  static Future<void> showBubble() async {
    final hasPerms = await FlutterOverlayWindow.isPermissionGranted();
    if (!hasPerms) return;

    await FlutterOverlayWindow.showOverlay(
      height: 70,
      width: 70,
      alignment: OverlayAlignment.centerRight,
      flag: OverlayFlag.defaultFlag,
      overlayTitle: 'Fracta',
      overlayContent: 'Tap to fact-check',
      enableDrag: true,
      positionGravity: PositionGravity.auto,
    );
    await _saveBubbleEnabled(true);
  }

  /// Hide the floating bubble.
  static Future<void> hideBubble() async {
    await FlutterOverlayWindow.closeOverlay();
    await _saveBubbleEnabled(false);
  }

  static Future<bool> get isBubbleVisible =>
      FlutterOverlayWindow.isActive();

  /// Stream of messages from the overlay widget back to the main app.
  static Stream<dynamic> get overlayMessages =>
      FlutterOverlayWindow.overlayListener;

  /// Send data to the overlay widget (e.g., verdict result).
  static Future<void> sendToOverlay(Map<String, dynamic> data) async {
    await FlutterOverlayWindow.shareData(data);
  }

  static Future<void> _saveBubbleEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBubbleEnabledKey, enabled);
  }

  static Future<bool> get wasBubbleEnabled async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kBubbleEnabledKey) ?? false;
  }
}