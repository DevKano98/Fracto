// ========== FILE: lib/services/sarvam_service.dart ==========
//
// Handles Sarvam voice features:
//  • language hint detection
//  • playing base64 audio responses
//  • audio lifecycle management
//

import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class SarvamService {
  final AudioPlayer _player = AudioPlayer();

  /// ─────────────────────────────────────────────
  /// Language Detection (Client-side hint)
  /// ─────────────────────────────────────────────

  String detectLanguageHint(String text) {
    if (text.trim().isEmpty) return "en-IN";

    final normalized = text.trim().toLowerCase();

    int devanagariCount = 0;
    int totalChars = 0;

    for (final rune in normalized.runes) {
      if (rune >= 0x0900 && rune <= 0x097F) {
        devanagariCount++;
      }
      if (rune > 32) totalChars++;
    }

    if (totalChars > 0 && devanagariCount / totalChars > 0.2) {
      return "hi-IN";
    }

    final romanizedHindiRegex = RegExp(
      r'\b(hai|kya|nahi|kyun|kab|kaise|ye|vo|aur|main|hum|tum|aap|iska|uska|raha|rahi|kar)\b',
      caseSensitive: false,
    );

    if (romanizedHindiRegex.hasMatch(normalized)) {
      return "hi-IN";
    }

    if (normalized.endsWith(" hai") ||
        normalized.endsWith(" kya") ||
        normalized.endsWith(" na")) {
      return "hi-IN";
    }

    return "en-IN";
  }

  /// ─────────────────────────────────────────────
  /// Audio Playback
  /// ─────────────────────────────────────────────

  Future<void> playAudioFromBase64(String base64Audio) async {
    try {
      if (base64Audio.isEmpty) return;

      final bytes = base64Decode(base64Audio);

      final tempDir = await getTemporaryDirectory();

      final filename =
          "sarvam_audio_${DateTime.now().millisecondsSinceEpoch}.wav";

      final file = File("${tempDir.path}/$filename");

      await file.writeAsBytes(bytes);

      await _player.setVolume(1.0);

      await _player.play(DeviceFileSource(file.path));

      _player.onPlayerComplete.first.then((_) {
        try {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      });
    } catch (e) {
      throw Exception("Sarvam audio playback failed: $e");
    }
  }

  /// ─────────────────────────────────────────────
  /// Audio Control
  /// ─────────────────────────────────────────────

  Future<void> stopAudio() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> pauseAudio() async {
    try {
      await _player.pause();
    } catch (_) {}
  }

  Future<void> resumeAudio() async {
    try {
      await _player.resume();
    } catch (_) {}
  }

  /// ─────────────────────────────────────────────
  /// Player State
  /// ─────────────────────────────────────────────

  Stream<PlayerState> get playerStateStream => _player.onPlayerStateChanged;

  PlayerState get playerState => _player.state;

  bool get isPlaying => _player.state == PlayerState.playing;

  /// ─────────────────────────────────────────────
  /// Cleanup
  /// ─────────────────────────────────────────────

  void dispose() {
    try {
      _player.dispose();
    } catch (_) {}
  }
}
