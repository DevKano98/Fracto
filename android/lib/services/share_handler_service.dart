// ========== FILE: lib/services/share_handler_service.dart ==========
//
// Handles incoming shares from external apps (WhatsApp, Chrome, Twitter etc).
// When user taps "Share → Fracta", this service receives the content and
// dispatches it to the Fracta background verification pipeline.
//

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'background_service.dart';

class ShareHandlerService {
  StreamSubscription<List<SharedMediaFile>>? _shareStreamSub;
  final Set<String> _processed = {};

  /// Initialize share listener.
  /// Should be called once (e.g., in root widget after login).
  void initialize({
    required void Function(String text, String sourceApp) onTextReceived,
    required void Function(String url, String sourceApp) onUrlReceived,
  }) {
    _listenWhileAppRunning(onTextReceived, onUrlReceived);
    _handleInitialShare(onTextReceived, onUrlReceived);
  }

  /// Dispose listeners
  void dispose() {
    _shareStreamSub?.cancel();
  }

  /// ─────────────────────────────────────────────
  /// Handle shares while app is open
  /// ─────────────────────────────────────────────

  void _listenWhileAppRunning(
    void Function(String text, String sourceApp) onTextReceived,
    void Function(String url, String sourceApp) onUrlReceived,
  ) {
    _shareStreamSub =
        ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      for (final file in files) {
        _handleIncomingShare(
          file,
          onTextReceived,
          onUrlReceived,
        );
      }
    }, onError: (err) {
      debugPrint("Share stream error: $err");
    });
  }

  /// ─────────────────────────────────────────────
  /// Handle share when app was opened via share
  /// ─────────────────────────────────────────────

  void _handleInitialShare(
    void Function(String text, String sourceApp) onTextReceived,
    void Function(String url, String sourceApp) onUrlReceived,
  ) async {
    try {
      final files = await ReceiveSharingIntent.instance.getInitialMedia();

      if (files.isEmpty) return;

      for (final file in files) {
        _handleIncomingShare(
          file,
          onTextReceived,
          onUrlReceived,
        );
      }

      ReceiveSharingIntent.instance.reset();
    } catch (e) {
      debugPrint("Initial share handling failed: $e");
    }
  }

  /// ─────────────────────────────────────────────
  /// Process incoming share
  /// ─────────────────────────────────────────────

  void _handleIncomingShare(
    SharedMediaFile file,
    void Function(String text, String sourceApp) onTextReceived,
    void Function(String url, String sourceApp) onUrlReceived,
  ) {
    if (file.type != SharedMediaType.text && file.type != SharedMediaType.url) {
      debugPrint("Ignoring non-text share: ${file.path}");
      return;
    }

    final content = file.path.trim();

    if (content.isEmpty) return;

    if (_processed.contains(content)) return;

    _processed.add(content);
    _scheduleCleanup(content);

    final source = _guessSourceApp(content);

    if (_looksLikeUrl(content)) {
      onUrlReceived(content, source);
      FractaBackgroundService.sendUrlForVerification(content);
    } else {
      onTextReceived(content, source);
      FractaBackgroundService.sendTextForVerification(content);
    }
  }

  /// ─────────────────────────────────────────────
  /// URL Detection
  /// ─────────────────────────────────────────────

  bool _looksLikeUrl(String input) {
    final s = input.trim().toLowerCase();

    if (s.startsWith("http://") || s.startsWith("https://")) {
      return true;
    }

    final urlRegex = RegExp(
      r'^(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/.*)?$',
      caseSensitive: false,
    );

    final blacklist = [
      ".m4a",
      ".wav",
      ".jpg",
      ".jpeg",
      ".png",
      ".mp4",
      ".json",
      ".txt"
    ];

    for (final ext in blacklist) {
      if (s.endsWith(ext)) return false;
    }

    return urlRegex.hasMatch(s);
  }

  /// ─────────────────────────────────────────────
  /// Source App Guessing
  /// ─────────────────────────────────────────────

  String _guessSourceApp(String content) {
    final c = content.toLowerCase();

    if (c.contains("twitter.com") || c.contains("t.co")) return "twitter";

    if (c.contains("facebook.com") || c.contains("fb.me")) return "facebook";

    if (c.contains("instagram.com")) return "instagram";

    if (c.contains("youtube.com") || c.contains("youtu.be")) return "youtube";

    if (c.contains("whatsapp")) return "whatsapp";

    if (c.contains("reddit.com")) return "reddit";

    if (c.contains("telegram.me") || c.contains("t.me")) return "telegram";

    return "unknown";
  }

  /// ─────────────────────────────────────────────
  /// Deduplication Cleanup
  /// ─────────────────────────────────────────────

  void _scheduleCleanup(String content) {
    Timer(const Duration(seconds: 5), () {
      _processed.remove(content);
    });
  }
}
