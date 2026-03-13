// ========== FILE: lib/providers/auth_provider.dart ==========

import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/background_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService;

  UserModel? _user;
  bool _isLoading = false;
  String? _error;

  AuthProvider({AuthService? authService})
      : _authService = authService ?? AuthService();

  UserModel? get user => _user;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _user != null;
  String? get error => _error;

  AuthService get authService => _authService;

  /// Called from SplashScreen to initialize auth state.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      // Try cached user first for instant UI
      _user = await _authService.getCachedUser();
      if (_user != null) notifyListeners();

      // Try to get fresh user from API
      final freshUser = await _authService.getCurrentUser();
      if (freshUser != null) {
        _user = freshUser;
        notifyListeners();
        return;
      }

      // Try token refresh
      final newToken = await _authService.refreshAccessToken();
      if (newToken != null) {
        final userAfterRefresh = await _authService.getCurrentUser();
        if (userAfterRefresh != null) {
          _user = userAfterRefresh;
          notifyListeners();
          return;
        }
      }

      // All attempts failed
      _user = null;
      notifyListeners();
    } catch (_) {
      _user = null;
      notifyListeners();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> login(String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _user = await _authService.login(email, password);
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } catch (e) {
      _error = 'An unexpected error occurred. Please try again.';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> register(
      String name, String email, String password, String? city) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _user = await _authService.register(name, email, password, city);
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } catch (e) {
      _error = 'An unexpected error occurred. Please try again.';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();
    try {
      // Point 20: Stop background service on logout
      await FractaBackgroundService.stop();

      final token = await _authService.getRefreshToken();
      if (token != null) {
        await _authService.logout(token);
      } else {
        await _authService.clearAll();
      }
    } catch (_) {
      await _authService.clearAll();
    } finally {
      _user = null;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<String?> getAccessToken() async {
    return await _authService.getAccessToken();
  }

  /// Attempts to refresh the access token, returns new token or null.
  Future<String?> refreshIfNeeded() async {
    final token = await _authService.getAccessToken();
    if (token == null) return null;
    if (!_authService.isTokenExpired(token)) return token;
    return await _authService.refreshAccessToken();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}