import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants.dart';
import '../models/user_model.dart';
import 'api_service.dart';

class AuthService {
  final FlutterSecureStorage _storage;
  final ApiService _api;

  static const _accessKey = AppConstants.accessTokenKey;
  static const _refreshKey = AppConstants.refreshTokenKey;
  static const _userKey = AppConstants.userJsonKey;

  AuthService({
    FlutterSecureStorage? storage,
    ApiService? apiService,
  })  : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
            ),
        _api = apiService ?? ApiService();

  /// =============================
  /// Authentication
  /// =============================

  Future<UserModel?> login(String email, String password) async {
    final response = await _api.login(email, password);

    final access = response['access_token']?.toString();
    final refresh = response['refresh_token']?.toString();
    final userJson = response['user'];

    if (access == null || refresh == null || userJson == null) {
      throw const ApiException(code: 0, message: "Invalid login response");
    }

    await _saveTokens(access, refresh);
    await _saveUser(userJson);

    return UserModel.fromJson(userJson);
  }

  Future<UserModel?> register(
      String name, String email, String password, String? city) async {
    final response = await _api.register(name, email, password, city);

    final access = response['access_token']?.toString();
    final refresh = response['refresh_token']?.toString();
    final userJson = response['user'];

    if (access == null || refresh == null || userJson == null) {
      throw const ApiException(code: 0, message: "Invalid register response");
    }

    await _saveTokens(access, refresh);
    await _saveUser(userJson);

    return UserModel.fromJson(userJson);
  }

  Future<void> logout() async {
    try {
      final access = await getAccessToken();
      final refresh = await getRefreshToken();

      if (access != null && refresh != null) {
        await _api.logout(refresh, access);
      }
    } catch (_) {
      // Best effort logout
    } finally {
      await clearAll();
    }
  }

  /// =============================
  /// User
  /// =============================

  Future<UserModel?> getCurrentUser() async {
    final token = await getAccessToken();

    if (token == null || token.isEmpty) return null;

    try {
      final data = await _api.getMe(token);
      await _saveUser(data);
      return UserModel.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<UserModel?> getCachedUser() async {
    final jsonStr = await _storage.read(key: _userKey);

    if (jsonStr == null) return null;

    try {
      return UserModel.fromJson(jsonDecode(jsonStr));
    } catch (_) {
      return null;
    }
  }

  /// =============================
  /// Token Management
  /// =============================

  Future<void> _saveTokens(String access, String refresh) async {
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: refresh);
  }

  Future<void> _saveUser(Map<String, dynamic> user) async {
    await _storage.write(key: _userKey, value: jsonEncode(user));
  }

  Future<String?> getAccessToken() async {
    return await _storage.read(key: _accessKey);
  }

  Future<String?> getRefreshToken() async {
    return await _storage.read(key: _refreshKey);
  }

  /// =============================
  /// Token Refresh
  /// =============================

  Future<String?> refreshAccessToken() async {
    final refresh = await getRefreshToken();

    if (refresh == null || refresh.isEmpty) {
      await clearAll();
      return null;
    }

    try {
      final data = await _api.refreshToken(refresh);

      final newAccess = data['access_token']?.toString();
      final newRefresh = data['refresh_token']?.toString() ?? refresh;

      if (newAccess == null) {
        await clearAll();
        return null;
      }

      await _saveTokens(newAccess, newRefresh);

      return newAccess;
    } catch (_) {
      await clearAll();
      return null;
    }
  }

  /// =============================
  /// Token Validation
  /// =============================

  bool isTokenExpired(String token) {
    try {
      final parts = token.split('.');

      if (parts.length != 3) return true;

      final payload = base64.normalize(parts[1]);

      final decoded = utf8.decode(base64Decode(payload));

      final jsonPayload = jsonDecode(decoded) as Map<String, dynamic>;

      final exp = jsonPayload['exp'];

      if (exp == null) return true;

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      return now >= exp;
    } catch (_) {
      return true;
    }
  }

  /// =============================
  /// Session Helpers
  /// =============================

  Future<bool> isLoggedIn() async {
    final token = await getAccessToken();

    if (token == null) return false;

    return !isTokenExpired(token);
  }

  Future<String?> getValidAccessToken() async {
    final token = await getAccessToken();

    if (token == null) return null;

    if (!isTokenExpired(token)) {
      return token;
    }

    return await refreshAccessToken();
  }

  /// =============================
  /// Storage
  /// =============================

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
