// ========== FILE: lib/services/auth_service.dart ==========

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../constants.dart';
import '../models/user_model.dart';
import 'api_service.dart';

class AuthService {
  final FlutterSecureStorage _storage;
  final ApiService _apiService;

  static const String _accessKey = AppConstants.accessTokenKey;
  static const String _refreshKey = AppConstants.refreshTokenKey;
  static const String _userKey = AppConstants.userJsonKey;

  AuthService({
    FlutterSecureStorage? storage,
    ApiService? apiService,
  })  : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
            ),
        _apiService = apiService ?? ApiService();

  Future<UserModel?> login(String email, String password) async {
    final data = await _apiService.login(email, password);
    final accessToken = data['access_token']?.toString() ?? '';
    final refreshToken = data['refresh_token']?.toString() ?? '';
    final userJson = data['user'] as Map<String, dynamic>? ?? {};
    await saveTokens(accessToken, refreshToken);
    await saveUser(userJson);
    return UserModel.fromJson(userJson);
  }

  Future<UserModel?> register(
      String name, String email, String password, String? city) async {
    final data = await _apiService.register(name, email, password, city);
    final accessToken = data['access_token']?.toString() ?? '';
    final refreshToken = data['refresh_token']?.toString() ?? '';
    final userJson = data['user'] as Map<String, dynamic>? ?? {};
    await saveTokens(accessToken, refreshToken);
    await saveUser(userJson);
    return UserModel.fromJson(userJson);
  }

  Future<void> logout(String refreshToken) async {
    try {
      final accessToken = await getAccessToken() ?? '';
      await _apiService.logout(refreshToken, accessToken);
    } catch (_) {
      // Best effort
    } finally {
      await clearAll();
    }
  }

  Future<UserModel?> getCurrentUser() async {
    final token = await getAccessToken();
    if (token == null || token.isEmpty) return null;
    try {
      final data = await _apiService.getMe(token);
      await saveUser(data);
      return UserModel.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<String?> refreshAccessToken() async {
    final refresh = await getRefreshToken();
    if (refresh == null || refresh.isEmpty) {
      await clearAll();
      return null;
    }
    try {
      final data = await _apiService.refreshToken(refresh);
      final newAccess = data['access_token']?.toString() ?? '';
      final newRefresh = data['refresh_token']?.toString() ?? refresh;
      await saveTokens(newAccess, newRefresh);
      return newAccess;
    } catch (_) {
      await clearAll();
      return null;
    }
  }

  Future<void> saveTokens(String access, String refresh) async {
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: refresh);
  }

  Future<String?> getAccessToken() async {
    return await _storage.read(key: _accessKey);
  }

  Future<String?> getRefreshToken() async {
    return await _storage.read(key: _refreshKey);
  }

  Future<void> saveUser(Map<String, dynamic> userJson) async {
    await _storage.write(key: _userKey, value: jsonEncode(userJson));
  }

  Future<UserModel?> getCachedUser() async {
    final jsonStr = await _storage.read(key: _userKey);
    if (jsonStr == null) return null;
    try {
      return UserModel.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  bool isTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = parts[1];
      final normalized = base64.normalize(payload);
      final decoded = utf8.decode(base64Decode(normalized));
      final json = jsonDecode(decoded) as Map<String, dynamic>;
      final exp = (json['exp'] as num?)?.toInt();
      if (exp == null) return true;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return now >= exp;
    } catch (_) {
      return true;
    }
  }
}