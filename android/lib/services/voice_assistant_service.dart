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
  String get wakePhrase => 'hey ${_assistantName.isEmpty ? AppConstants.defaultAssistantName : _assistantName}'.toLowerCase();

  ClaimModel? _lastClaim;
  ClaimModel? get lastClaim => _lastClaim;

  final StreamController<VoiceAssistantState> _stateController = StreamController.broadcast();
  Stream<VoiceAssistantState> get events => _stateController.stream;

  bool _isSpeechAvailable = false;
  bool _hasMicPermission = false;
  bool _isManualStop = false;

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
    _assistantName = prefs.getString(AppConstants.assistantNameKey) ?? AppConstants.defaultAssistantName;
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
           Future.delayed(const Duration(seconds: 3), () => _setState(VoiceAssistantState.idle));
        }
      },
      onStatus: (status) {
        print('Speech recognition status: $status');
        // Point 3: Restart speech after stop if we are idle
        if (status == 'done' && _state == VoiceAssistantState.idle && !_isManualStop) {
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
          final hasHey = text.contains('hey') || text.contains('hi') || text.contains('ok');
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
    await _speech.cancel(); // Point 4: Cancel instead of stop
    _setState(VoiceAssistantState.woken);
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
      Future.delayed(const Duration(seconds: 2), () => _setState(VoiceAssistantState.idle));
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

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConstants.baseUrl}/verify/voice'),
      );

      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'voice_claim.wav',
      ));

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode == 200) {
        _lastClaim = ClaimModel.fromJson(jsonResponse);
        await _playResponse();
      } else {
        _setState(VoiceAssistantState.error);
        // Point 20: Path back to idle after error
        Future.delayed(const Duration(seconds: 3), () => _setState(VoiceAssistantState.idle));
      }
    } catch (e) {
      _setState(VoiceAssistantState.error);
      Future.delayed(const Duration(seconds: 3), () => _setState(VoiceAssistantState.idle));
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
      await _tts.speak(_lastClaim?.correctiveResponse ?? 'Unable to verify the claim.');
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