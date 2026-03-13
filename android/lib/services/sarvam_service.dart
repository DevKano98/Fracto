// ========== FILE: lib/services/sarvam_service.dart ==========

import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class SarvamService {
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// Simple client-side language detection before sending to backend.
  String detectLanguageHint(String text) {
    if (text.isEmpty) return 'en-IN';

    // Count Devanagari characters (U+0900–U+097F)
    int devanagariCount = 0;
    int totalChars = 0;
    for (final rune in text.runes) {
      if (rune >= 0x0900 && rune <= 0x097F) {
        devanagariCount++;
      }
      if (rune > 32) totalChars++; // non-whitespace
    }

    if (totalChars > 0 && devanagariCount / totalChars > 0.2) {
      return 'hi-IN';
    }

    // Check for common Romanized Hindi patterns
    final lowerText = text.toLowerCase();
    
    // Pattern 1: Common Romanized Hindi words
    final romanizedHindiRegex = RegExp(
      r'\b(hai|kya|nahi|ye|vo|aur|main|hum|tum|aap|iska|uska|kar|raha|tho|kyun|kab|kaise)\b',
      caseSensitive: false,
    );
    
    if (romanizedHindiRegex.hasMatch(lowerText)) {
      return 'hi-IN';
    }

    // Pattern 2: ROMANIZED HINDI heuristic (Check for missing common English patterns)
    // If it has "hai" or "kya" at the end, it's very likely Hindi
    if (lowerText.endsWith(' hai') || lowerText.endsWith(' kya') || lowerText.endsWith(' na')) {
      return 'hi-IN';
    }

    return 'en-IN';
  }

  /// Plays audio from a base64-encoded WAV string.
  Future<void> playAudioFromBase64(String base64Audio) async {
    try {
      final bytes = base64Decode(base64Audio);
      final tempDir = await getTemporaryDirectory();
      // Point 9: Use unique filename to prevent collision
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${tempDir.path}/sarvam_response_$timestamp.wav');
      await file.writeAsBytes(bytes);
      await _audioPlayer.setVolume(1.0); // Point 19: Set default volume
      await _audioPlayer.play(DeviceFileSource(file.path));
      
      // Cleanup after play (optional but good for long-term storage)
      _audioPlayer.onPlayerComplete.first.then((_) {
        if (file.existsSync()) file.deleteSync();
      });
    } catch (e) {
      throw Exception('Failed to play audio: $e');
    }
  }

  /// Stops any currently playing audio.
  Future<void> stopAudio() async {
    await _audioPlayer.stop();
  }

  /// Returns the current audio player state stream.
  Stream<PlayerState> get playerStateStream => _audioPlayer.onPlayerStateChanged;

  /// Returns current player state.
  PlayerState get playerState => _audioPlayer.state;

  void dispose() {
    _audioPlayer.dispose();
  }
}