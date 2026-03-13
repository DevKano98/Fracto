// ========== FILE: lib/providers/claim_provider.dart ==========

import 'package:flutter/foundation.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import '../services/api_service.dart';

class ClaimProvider extends ChangeNotifier {
  final ApiService _apiService;

  ClaimProvider({ApiService? apiService})
      : _apiService = apiService ?? ApiService();

  ClaimModel? _currentClaim;
  final List<ClaimModel> _history = [];

  bool _isLoading = false;
  bool _isLoadingHistory = false;

  String? _error;

  int _historyOffset = 0;
  bool _hasMoreHistory = true;

  ClaimModel? get currentClaim => _currentClaim;

  List<ClaimModel> get history => List.unmodifiable(_history);

  bool get isLoading => _isLoading;

  bool get isLoadingHistory => _isLoadingHistory;

  String? get error => _error;

  bool get hasMoreHistory => _hasMoreHistory;

  // ===============================
  // Verify Claim
  // ===============================

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
    if (_isLoading) return null;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      late Map<String, dynamic> json;

      switch (type) {
        case InputType.text:
          if (text == null || text.trim().isEmpty) {
            throw Exception("Text cannot be empty");
          }

          json = await _apiService.verifyText(
            text: text.trim(),
            platform: platform,
            shares: shares,
            token: accessToken,
          );

          break;

        case InputType.image:
          if (imageBytes == null || imageBytes.isEmpty) {
            throw Exception("Image bytes missing");
          }

          json = await _apiService.verifyImage(
            imageBytes: imageBytes,
            filename: imageFilename ?? "image.jpg",
            platform: platform,
            shares: shares,
            token: accessToken,
          );

          break;

        case InputType.url:
          if (url == null || url.trim().isEmpty) {
            throw Exception("URL cannot be empty");
          }

          json = await _apiService.verifyUrl(
            url: url.trim(),
            platform: platform,
            shares: shares,
            token: accessToken,
          );

          break;

        case InputType.voice:
          if (audioBytes == null || audioBytes.isEmpty) {
            throw Exception("Audio bytes missing");
          }

          json = await _apiService.verifyVoice(
            audioBytes: audioBytes,
            filename: audioFilename ?? "recording.wav",
            platform: platform,
            shares: shares,
            accessToken: accessToken,
          );

          break;
      }

      final claim = ClaimModel.fromJson(json);

      _currentClaim = claim;

      return claim;
    } on ApiException catch (e) {
      _error = e.message;

      return null;
    } catch (_) {
      _error = "An unexpected error occurred. Please try again.";

      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ===============================
  // History
  // ===============================

  Future<void> loadHistory(
    String accessToken, {
    bool refresh = false,
  }) async {
    if (_isLoadingHistory) return;

    if (refresh) {
      _history.clear();
      _historyOffset = 0;
      _hasMoreHistory = true;
      _error = null;
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

      final claims = items.map(ClaimModel.fromJson).toList();

      _history.addAll(claims);

      _historyOffset += claims.length;

      if (claims.length < 20) {
        _hasMoreHistory = false;
      }
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = "Failed to load history.";
    } finally {
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  // ===============================
  // Report Claim
  // ===============================

  Future<void> reportClaim({
    required String claimId,
    required String reportType,
    String? note,
    String? accessToken,
  }) async {
    try {
      await _apiService.reportClaim(
        claimId: claimId,
        reportType: reportType,
        note: note,
        accessToken: accessToken,
      );
    } catch (e) {
      _error = "Failed to report claim.";
      notifyListeners();
    }
  }

  // ===============================
  // Utility
  // ===============================

  void clearCurrentClaim() {
    if (_currentClaim == null) return;

    _currentClaim = null;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;

    _error = null;
    notifyListeners();
  }

  void clearHistory() {
    _history.clear();
    _historyOffset = 0;
    _hasMoreHistory = true;

    notifyListeners();
  }
}
