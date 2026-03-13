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

  StreamSubscription? _speechSubscription;
  Timer? _wakeTimeout;
  Timer? _listenTimeout;

  String _assistantName = AppConstants.defaultAssistantName;
  String get assistantName => _assistantName;
  String get wakePhrase => 'hey $_assistantName'.toLowerCase();

  ClaimModel? _lastClaim;
  ClaimModel? get lastClaim => _lastClaim;

  final StreamController<VoiceAssistantState> _stateController = StreamController.broadcast();
  Stream<VoiceAssistantState> get events => _stateController.stream;

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
    final available = await _speech.initialize(
      onError: (error) => print('Speech recognition error: $error'),
      onStatus: (status) => print('Speech recognition status: $status'),
    );
    if (!available) {
      print('Speech recognition not available');
      _setState(VoiceAssistantState.error);
    } else {
      print('Speech recognition initialized successfully');
    }
  }

  Future<void> startListening() async {
    if (_state != VoiceAssistantState.idle) return;

    _setState(VoiceAssistantState.idle);

    await _speech.listen(
      onResult: (result) {
        final text = result.recognizedWords.toLowerCase();
        debugPrint('Speech recognized: "$text"'); // Use debugPrint
        debugPrint('Wake phrase: "$wakePhrase"'); 
        if (text.contains(wakePhrase)) {
          debugPrint('Wake phrase detected!'); 
          _onWakeDetected();
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      partialResults: true,
      listenMode: stt.ListenMode.confirmation,
    );
  }

  void _onWakeDetected() {
    _speech.stop(); // Stop current listening
    _setState(VoiceAssistantState.woken);
    _speakPrompt();
  }

  Future<void> _speakPrompt() async {
    _setState(VoiceAssistantState.speaking);
    await _tts.speak('What do you want to check?');
    await Future.delayed(const Duration(seconds: 2)); // Wait for TTS to finish
    _startRecording();
  }

  Future<void> _startRecording() async {
    _setState(VoiceAssistantState.listening);

    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/voice_claim.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: path,
    );

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
        filename: 'voice_claim.m4a',
      ));

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode == 200) {
        _lastClaim = ClaimModel.fromJson(jsonResponse);
        await _playResponse();
      } else {
        _setState(VoiceAssistantState.error);
      }
    } catch (e) {
      _setState(VoiceAssistantState.error);
    }
  }

  Future<void> _playResponse() async {
    if (_lastClaim?.aiAudioB64 != null) {
      _setState(VoiceAssistantState.speaking);
      final audioBytes = base64Decode(_lastClaim!.aiAudioB64!);
      await _audioPlayer.play(BytesSource(audioBytes));
      await _audioPlayer.onPlayerComplete.first;
    } else {
      _setState(VoiceAssistantState.speaking);
      await _tts.speak(_lastClaim?.correctiveResponse ?? 'Unable to verify the claim.');
      await Future.delayed(const Duration(seconds: 3));
    }

    _setState(VoiceAssistantState.idle);
    await startListening(); // Loop back
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
    _speechSubscription?.cancel();
    _wakeTimeout?.cancel();
    _listenTimeout?.cancel();
    _recorder.dispose();
    _audioPlayer.dispose();
    _tts.stop();
    _stateController.close();
    super.dispose();
  }
}