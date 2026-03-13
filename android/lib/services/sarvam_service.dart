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

    // Check for common Hindi words romanized
    const hindiWords = [
      'hai',
      'kya',
      'nahi',
      'ye',
      'vo',
      'aur',
      'main',
      'hum',
      'tum',
      'aap',
      'iska',
      'uska',
    ];
    final lowerText = text.toLowerCase();
    for (final word in hindiWords) {
      if (lowerText.contains(' $word ') ||
          lowerText.startsWith('$word ') ||
          lowerText.endsWith(' $word')) {
        return 'hi-IN';
      }
    }

    return 'en-IN';
  }

  /// Plays audio from a base64-encoded WAV string.
  Future<void> playAudioFromBase64(String base64Audio) async {
    try {
      final bytes = base64Decode(base64Audio);
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/response.wav');
      await file.writeAsBytes(bytes);
      await _audioPlayer.play(DeviceFileSource(file.path));
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