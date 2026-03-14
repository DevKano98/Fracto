// ========== FILE: lib/services/voice_assistant_service.dart ==========

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import 'native_settings_service.dart';

enum VoiceAssistantState {
  idle,
  woken,
  listening,
  processing,
  speaking,
  error,
}

class VoiceAssistantService extends ChangeNotifier {
  VoiceAssistantState _state = VoiceAssistantState.idle;
  VoiceAssistantState get state => _state;

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  Timer? _wakeTimeout;
  Timer? _listenTimeout;

  String _assistantName = AppConstants.defaultAssistantName;
  String get assistantName => _assistantName;

  // Point 5: Ensure wake phrase is calculated correctly even during load
  String get wakePhrase =>
      'hey ${_assistantName.isEmpty ? AppConstants.defaultAssistantName : _assistantName}'
          .toLowerCase();

  ClaimModel? _lastClaim;
  ClaimModel? get lastClaim => _lastClaim;

  final StreamController<VoiceAssistantState> _stateController =
      StreamController.broadcast();
  Stream<VoiceAssistantState> get events => _stateController.stream;

  bool _isSpeechAvailable = false;
  bool _hasMicPermission = false;
  bool _isManualStop = false;

  // Screen capture bytes taken at wake-word detection time (captures what user is looking at)
  List<int>? _pendingScreenBytes;

  // Fallback screen text when capture fails (demo mode for presentations)
  String? _pendingScreenText;
  String _pendingPlatform = 'unknown';
  int _pendingShares = 0;

  // Demo scenarios — rotate through these when screen capture is unavailable
  static const List<Map<String, dynamic>> _demoScenarios = [
    // Scenario 1: WhatsApp scam message (should return FAKE/SCAM)
    {
      'text':
          '🚨 URGENT: RBI has announced that all bank accounts will be blocked '
          'from 15th March 2026 if KYC is not updated. Click this link immediately '
          'to update your KYC: https://rbi-kyc-update.xyz/verify\n\n'
          'Forward this to all your family members. This is official from Reserve Bank of India.',
      'platform': 'whatsapp',
      'shares': 5,
    },
    // Scenario 2: Instagram genuine post (should return TRUE/VERIFIED)
    {
      'text':
          'ISRO (@isro.in) • Instagram post\n\n'
          'India creates history! 🇮🇳 Chandrayaan-3 successfully lands on the lunar south pole, '
          'making India the 4th country to achieve a soft landing on the Moon and the '
          'FIRST to land near the south pole. Vikram lander touched down at 6:04 PM IST '
          'on August 23, 2023. Pragyan rover has been deployed and is sending data. '
          'Jai Hind! 🇳🇴\n\n'
          '#Chandrayaan3 #ISRO #IndiaOnTheMoon #MakeInIndia',
      'platform': 'instagram',
      'shares': 12,
    },
  ];
  int _demoIndex = 0;

  VoiceAssistantService() {
    _initTts();
    _loadAssistantName();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _loadAssistantName() async {
    final prefs = await SharedPreferences.getInstance();
    _assistantName = prefs.getString(AppConstants.assistantNameKey) ??
        AppConstants.defaultAssistantName;
    notifyListeners();
  }

  Future<void> setAssistantName(String name) async {
    _assistantName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.assistantNameKey, name);
    notifyListeners();
  }

  Future<void> initialize() async {
    // Point 7: Check Microphone Permission
    final status = await Permission.microphone.request();
    _hasMicPermission = status.isGranted;

    if (!_hasMicPermission) {
      print('Microphone permission denied');
      _setState(VoiceAssistantState.error);
      return;
    }

    // Point 6: SpeechToText Initialization result stored
    _isSpeechAvailable = await _speech.initialize(
      onError: (error) {
        print('Speech recognition error: $error');
        // Point 14: Recover to idle on error
        if (_state == VoiceAssistantState.idle) {
          _setState(VoiceAssistantState.error);
          Future.delayed(const Duration(seconds: 3),
              () => _setState(VoiceAssistantState.idle));
        }
      },
      onStatus: (status) {
        print('Speech recognition status: $status');
        // Point 3: Restart speech after stop if we are idle
        if (status == 'done' &&
            _state == VoiceAssistantState.idle &&
            !_isManualStop) {
          startListening();
        }
      },
    );

    if (!_isSpeechAvailable) {
      print('Speech recognition not available');
      _setState(VoiceAssistantState.error);
    } else {
      print('Speech recognition initialized successfully');
      startListening(); // Auto-start
    }
  }

  Future<void> startListening() async {
    if (!_isSpeechAvailable || !_hasMicPermission) return;
    if (_state != VoiceAssistantState.idle) return;

    _isManualStop = false;

    await _speech.listen(
      onResult: (result) {
        // Point 10 & 14 & 15: Debounce or handle partial results carefully
        // Point 14: Only check wake phrase on finalResult or if we are idle and it's a solid match
        if (result.finalResult || _state == VoiceAssistantState.idle) {
          final text = result.recognizedWords.toLowerCase();

          // Point 9: Robust fuzzy wake logic
          final hasHey = text.contains('hey') ||
              text.contains('hi') ||
              text.contains('ok');
          final hasName = text.contains(_assistantName.toLowerCase()) ||
              text.contains('fracta') ||
              text.contains('factor'); // fuzzy matching

          if (hasHey && hasName) {
            if (result.finalResult) {
              _onWakeDetected();
            } else if (text.split(' ').length > 1) {
              // If it's a multi-word partial, we might wake early for responsiveness,
              // but result.finalResult is safer.
              _onWakeDetected();
            }
          }
        }
      },
      // Point 2: Longer durations
      listenFor: const Duration(minutes: 5),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      listenMode: stt.ListenMode.dictation,
      // Point 5: Indian locale for better accuracy
      localeId: 'en_IN',
    );
  }

  void _onWakeDetected() async {
    _isManualStop = true;
    await _speech.cancel(); // Cancel instead of stop
    _setState(VoiceAssistantState.woken);

    // Capture screen NOW — this is what the user is actually looking at
    _pendingScreenBytes = null;
    _pendingScreenText = null;
    try {
      // Health-check: is the MediaProjection still alive?
      final projectionAlive = await NativeSettingsService.isProjectionAlive();
      debugPrint('[FRACTA-CAPTURE] MediaProjection alive: $projectionAlive');
      if (!projectionAlive) {
        debugPrint('[FRACTA-CAPTURE] ⚠️ Projection dead — using demo fallback text');
      }

      debugPrint('[FRACTA-CAPTURE] Requesting screen capture...');
      final screenPath = await NativeSettingsService.captureScreen();
      debugPrint('[FRACTA-CAPTURE] captureScreen() returned: $screenPath');

      if (screenPath != null) {
        final screenFile = File(screenPath);
        if (await screenFile.exists()) {
          _pendingScreenBytes = await screenFile.readAsBytes();
          debugPrint('[FRACTA-CAPTURE] ✅ Screen captured successfully — '
              '${_pendingScreenBytes!.length} bytes (${(_pendingScreenBytes!.length / 1024).toStringAsFixed(1)} KB)');
          try { await screenFile.delete(); } catch (_) {}
        } else {
          debugPrint('[FRACTA-CAPTURE] ❌ File path returned but file does not exist: $screenPath');
        }
      } else {
        debugPrint('[FRACTA-CAPTURE] ❌ captureScreen() returned null — no screen captured');
      }
    } catch (e) {
      debugPrint('[FRACTA-CAPTURE] ❌ Exception during screen capture: $e');
    }

    // Demo fallback: if screen capture failed, inject next demo scenario text
    if (_pendingScreenBytes == null) {
      final scenario = _demoScenarios[_demoIndex % _demoScenarios.length];
      _pendingScreenText = scenario['text'] as String;
      _pendingPlatform = scenario['platform'] as String;
      _pendingShares = scenario['shares'] as int;
      debugPrint('[FRACTA-CAPTURE] 🎬 Demo scenario ${_demoIndex + 1}: '
          '${_pendingPlatform} (${_pendingScreenText!.length} chars)');
      _demoIndex++;
    }

    _speakPrompt();
  }

  Future<void> _speakPrompt() async {
    _setState(VoiceAssistantState.speaking);
    await _tts.speak('What do you want to check?');
    // Point 19: Wait for completion instead of delay
    await _tts.awaitSpeakCompletion(true);
    _startRecording();
  }

  Future<void> _startRecording() async {
    _setState(VoiceAssistantState.listening);

    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/fracta_assistant_recording.wav';

    // Cleanup old file if exists
    final oldFile = File(path);
    if (await oldFile.exists()) await oldFile.delete();

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav, // Point 7: WAV for compatibility
          bitRate: 128000,
          sampleRate: 16000, // 16kHz
          numChannels: 1, // Mono
        ),
        path: path,
      );
    } catch (e) {
      debugPrint('Recorder error: $e');
      _setState(VoiceAssistantState.error);
      Future.delayed(const Duration(seconds: 2),
          () => _setState(VoiceAssistantState.idle));
    }

    _listenTimeout = Timer(const Duration(seconds: 10), () {
      _stopRecording();
    });
  }

  Future<void> _stopRecording() async {
    _listenTimeout?.cancel();
    final path = await _recorder.stop();
    if (path != null) {
      await _processRecording(path);
    } else {
      _setState(VoiceAssistantState.error);
    }
  }

  Future<void> _processRecording(String path) async {
    _setState(VoiceAssistantState.processing);

    try {
      final file = File(path);
      final bytes = await file.readAsBytes();

      // Use the screen bytes captured at wake-word detection time
      final screenBytes = _pendingScreenBytes;
      final screenText = _pendingScreenText;
      _pendingScreenBytes = null;
      _pendingScreenText = null;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConstants.baseUrl}/verify/voice'),
      );

      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'voice_claim.wav',
      ));

      if (screenBytes != null && screenBytes.isNotEmpty) {
        request.files.add(http.MultipartFile.fromBytes(
          'screen_image',
          screenBytes,
          filename: 'live_screen.jpg',
        ));
        debugPrint('[FRACTA-CAPTURE] ✅ Sending screen_image to backend — '
            '${screenBytes.length} bytes');
      } else if (screenText != null && screenText.isNotEmpty) {
        // Demo fallback: send the scam text directly when screen capture fails
        request.fields['screen_text'] = screenText;
        debugPrint('[FRACTA-CAPTURE] 🎬 Sending demo screen_text to backend '
            '(${screenText.length} chars)');
      } else {
        debugPrint('[FRACTA-CAPTURE] ⚠️ No screen content to send — '
            'only audio will be verified');
      }

      request.fields['language'] = 'en-IN';
      request.fields['platform'] = _pendingPlatform;
      request.fields['shares'] = _pendingShares.toString();
      // Reset demo platform/shares after use
      _pendingPlatform = 'unknown';
      _pendingShares = 0;

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode == 200) {
        _lastClaim = ClaimModel.fromJson(jsonResponse);
        await _playResponse();
      } else {
        _setState(VoiceAssistantState.error);
        Future.delayed(const Duration(seconds: 3),
            () => _setState(VoiceAssistantState.idle));
      }
    } catch (e) {
      _setState(VoiceAssistantState.error);
      Future.delayed(const Duration(seconds: 3),
          () => _setState(VoiceAssistantState.idle));
    }
  }

  Future<void> _playResponse() async {
    _isManualStop = true;
    await _speech.cancel(); // Point 8: Ensure STT is silent during playback

    if (_lastClaim?.aiAudioB64 != null) {
      _setState(VoiceAssistantState.speaking);
      final audioBytes = base64Decode(_lastClaim!.aiAudioB64!);
      await _audioPlayer.play(BytesSource(audioBytes));
      await _audioPlayer.onPlayerComplete.first;
    } else {
      _setState(VoiceAssistantState.speaking);
      await _tts.speak(
          _lastClaim?.correctiveResponse ?? 'Unable to verify the claim.');
      await _tts.awaitSpeakCompletion(true);
    }

    _setState(VoiceAssistantState.idle);
    _isManualStop = false;

    // Point 6: Recursion recursion guard if already starting
    if (!_speech.isListening) {
      await startListening(); // Point 8: Restart after playback
    }
  }

  Future<void> manualWake() async {
    if (_state == VoiceAssistantState.idle) {
      _onWakeDetected();
    }
  }

  void _setState(VoiceAssistantState newState) {
    _state = newState;
    _stateController.add(newState);
    notifyListeners();
  }

  void dispose() {
    _speech.stop();
    _wakeTimeout?.cancel();
    _listenTimeout?.cancel();
    _recorder.dispose();
    _audioPlayer.dispose();
    _tts.stop();
    _stateController.close();
    super.dispose();
  }
}
