// ========== FILE: lib/services/share_handler_service.dart ==========
//
// Handles incoming shares from other apps (WhatsApp, Chrome, Twitter etc.)
// When user taps "Share → Fracta" in any app, this service receives the
// text/URL and immediately dispatches it for verification.
//

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'background_service.dart';

class ShareHandlerService {
  StreamSubscription? _intentSub;
  StreamSubscription? _mediaIntentSub;

  // Point 18: Deduplication set to prevent double processing of sharing events
  final Set<String> _processedContent = {};

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
        // Point 8: Distinguish between shared text and shared file paths
        if (file.type != SharedMediaType.text && file.type != SharedMediaType.url) {
          debugPrint('Ignoring non-text share: ${file.path}');
          continue;
        }
        
        final content = file.path; 
        if (content.isEmpty || _processedContent.contains(content)) continue;
        
        _processedContent.add(content);
        _scheduleCleanup(content);

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
      if (files.isEmpty) return;
      
      for (final file in files) {
        // Point 11: Ignore non-text/url media (images/video share handled elsewhere)
        if (file.type != SharedMediaType.text && file.type != SharedMediaType.url) {
          debugPrint('Ignoring non-text initial share: ${file.path}');
          continue;
        }
        
        final content = file.path;
        if (content.isEmpty || _processedContent.contains(content)) continue;

        _processedContent.add(content);
        _scheduleCleanup(content);

        if (_looksLikeUrl(content)) {
          onUrlReceived(content, _guessSourceApp(content));
          FractaBackgroundService.sendUrlForVerification(content);
        } else {
          onTextReceived(content, _guessSourceApp(content));
          FractaBackgroundService.sendTextForVerification(content);
        }
      }
      ReceiveSharingIntent.instance.reset();
    });
  }

  void dispose() {
    _intentSub?.cancel();
    _mediaIntentSub?.cancel();
  }

  bool _looksLikeUrl(String s) {
    final trimmed = s.trim().toLowerCase();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return true;
    
    // Stricter regex for URL-like patterns without protocol
    // Avoids matching local file paths like file.txt or config.json
    final urlRegex = RegExp(
      r'^(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/.*)?$',
      caseSensitive: false,
    );
    
    // Blacklist common file extensions that aren't TLDs in this context
    final fileExtensions = ['.m4a', '.wav', '.jpg', '.png', '.json', '.txt', '.mp4'];
    if (fileExtensions.any((ext) => trimmed.endsWith(ext))) return false;

    return urlRegex.hasMatch(trimmed);
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

  void _scheduleCleanup(String content) {
    // Clear from deduplication set after 5 seconds
    Timer(const Duration(seconds: 5), () => _processedContent.remove(content));
  }
}