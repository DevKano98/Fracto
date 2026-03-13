// ========== FILE: lib/services/share_handler_service.dart ==========
//
// Handles incoming shares from other apps (WhatsApp, Chrome, Twitter etc.)
// When user taps "Share → Fracta" in any app, this service receives the
// text/URL and immediately dispatches it for verification.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'background_service.dart';

class ShareHandlerService {
  StreamSubscription? _intentSub;
  StreamSubscription? _mediaIntentSub;

  /// Must be called from a StatefulWidget that lives for the app lifetime
  /// (e.g., the root widget after login). Pass a callback to handle
  /// the received content in the UI.
  void initialize({
    required void Function(String text, String sourceApp) onTextReceived,
    required void Function(String url, String sourceApp) onUrlReceived,
  }) {
    // ── While app is already open ──────────────────────────────────
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen((List<SharedMediaFile> files) {
      for (final file in files) {
        final content = file.path;
        if (_looksLikeUrl(content)) {
          onUrlReceived(content, _guessSourceApp(content));
          FractaBackgroundService.sendUrlForVerification(content);
        } else {
          onTextReceived(content, _guessSourceApp(content));
          FractaBackgroundService.sendTextForVerification(content);
        }
      }
    });

    // ── App was launched/resumed via share intent ──────────────────
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then((List<SharedMediaFile> files) {
      for (final file in files) {
        final content = file.path;
        if (_looksLikeUrl(content)) {
          onUrlReceived(content, _guessSourceApp(content));
          FractaBackgroundService.sendUrlForVerification(content);
        } else {
          onTextReceived(content, _guessSourceApp(content));
          FractaBackgroundService.sendTextForVerification(content);
        }
      }
      // Reset after consuming
      ReceiveSharingIntent.instance.reset();
    });
  }

  void dispose() {
    _intentSub?.cancel();
    _mediaIntentSub?.cancel();
  }

  bool _looksLikeUrl(String s) {
    final trimmed = s.trim();
    return trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        RegExp(r'^[\w-]+\.[\w.]{2,}').hasMatch(trimmed);
  }

  String _guessSourceApp(String content) {
    // Heuristics based on content patterns
    if (content.contains('twitter.com') || content.contains('t.co')) return 'twitter';
    if (content.contains('facebook.com') || content.contains('fb.me')) return 'facebook';
    if (content.contains('instagram.com')) return 'instagram';
    if (content.contains('youtube.com') || content.contains('youtu.be')) return 'youtube';
    if (content.contains('whatsapp')) return 'whatsapp';
    // WhatsApp forwards often have "Forwarded as received" or are plain text
    return 'unknown';
  }
}