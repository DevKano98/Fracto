// ========== FILE: lib/providers/claim_provider.dart ==========

import 'package:flutter/foundation.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import '../services/api_service.dart';

class ClaimProvider extends ChangeNotifier {
  final ApiService _apiService;

  ClaimModel? _currentClaim;
  List<ClaimModel> _history = [];
  bool _isLoading = false;
  bool _isLoadingHistory = false;
  String? _error;
  int _historyOffset = 0;
  bool _hasMoreHistory = true;

  ClaimProvider({ApiService? apiService})
      : _apiService = apiService ?? ApiService();

  ClaimModel? get currentClaim => _currentClaim;
  List<ClaimModel> get history => _history;
  bool get isLoading => _isLoading;
  bool get isLoadingHistory => _isLoadingHistory;
  String? get error => _error;
  bool get hasMoreHistory => _hasMoreHistory;

  Future<ClaimModel?> verifyClaim({
    required InputType type,
    String? text,
    List<int>? imageBytes,
    String? imageFilename,
    String? url,
    List<int>? audioBytes,
    String? audioFilename,
    String platform = 'unknown',
    int shares = 0,
    String? accessToken,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      Map<String, dynamic> json;
      switch (type) {
        case InputType.text:
          json = await _apiService.verifyText(
            text: text ?? '',
            platform: platform,
            shares: shares,
            accessToken: accessToken,
          );
          break;
        case InputType.image:
          json = await _apiService.verifyImage(
            imageBytes: imageBytes ?? [],
            filename: imageFilename ?? 'image.jpg',
            platform: platform,
            shares: shares,
            accessToken: accessToken,
          );
          break;
        case InputType.url:
          json = await _apiService.verifyUrl(
            url: url ?? '',
            platform: platform,
            shares: shares,
            accessToken: accessToken,
          );
          break;
        case InputType.voice:
          json = await _apiService.verifyVoice(
            audioBytes: audioBytes ?? [],
            filename: audioFilename ?? 'recording.wav',
            platform: platform,
            shares: shares,
            accessToken: accessToken,
          );
          break;
      }

      _currentClaim = ClaimModel.fromJson(json);
      notifyListeners();
      return _currentClaim;
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    } catch (e) {
      _error = 'An unexpected error occurred. Please try again.';
      notifyListeners();
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadHistory(String accessToken, {bool refresh = false}) async {
    if (refresh) {
      _history = [];
      _historyOffset = 0;
      _hasMoreHistory = true;
    }
    if (!_hasMoreHistory) return;

    _isLoadingHistory = true;
    notifyListeners();

    try {
      final items = await _apiService.getFeed(
        accessToken: accessToken,
        limit: 20,
        offset: _historyOffset,
      );
      _history.addAll(items.map(ClaimModel.fromJson));
      _historyOffset += items.length;
      _hasMoreHistory = items.length == 20;
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Failed to load history.';
    } finally {
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  Future<void> reportClaim({
    required String claimId,
    required String reportType,
    String? note,
    String? accessToken,
  }) async {
    await _apiService.reportClaim(
      claimId: claimId,
      reportType: reportType,
      note: note,
      accessToken: accessToken,
    );
  }

  void clearCurrentClaim() {
    _currentClaim = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}