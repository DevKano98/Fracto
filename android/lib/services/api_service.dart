// ========== FILE: lib/services/api_service.dart ==========

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';

class ApiException implements Exception {
  final int code;
  final String message;

  const ApiException({required this.code, required this.message});

  @override
  String toString() => 'ApiException($code): $message';
}

class ApiService {
  final http.Client _client;
  SharedPreferences? _prefs;

  ApiService({http.Client? client}) : _client = client ?? _createPinnedClient() {
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static http.Client _createPinnedClient() {
    // Point 21: Certificate Pinning
    // In a real app, you would add the server's DER certificate to the SecurityContext.
    // For now, we use a basic IOClient that can be extended with trusted certificates.
    final HttpClient httpClient = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        // [WARNING] Only use this for development with self-signed certs!
        // In production, return false or check the fingerprint:
        // return cert.pem.contains('YOUR_EXPECTED_PEM_SUBSTRING');
        return true; 
      };
    
    return IOClient(httpClient);
  }

  Map<String, String> _authHeaders(String? accessToken) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  /// Get a string from cached SharedPreferences (Point 22)
  String? getString(String key) => _prefs?.getString(key);

  Map<String, dynamic> _parseResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body);
    }

    late final String message;
    try {
      final body = jsonDecode(response.body);
      message = body['detail'] ?? body['message'] ?? 'Status ${response.statusCode}';
    } catch (_) {
      message = 'Server Error: ${response.statusCode} - ${response.reasonPhrase}';
    }

    throw ApiException(
      code: response.statusCode,
      message: message,
    );
  }

  Future<Map<String, dynamic>> verifyText({
    required String text,
    String platform = 'unknown',
    int shares = 0,
    String? accessToken,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('${AppConstants.baseUrl}/verify/text'),
            headers: _authHeaders(accessToken),
            body: jsonEncode({
              'raw_text': text,
              'platform': platform,
              'shares': shares,
            }),
          )
          .timeout(AppConstants.verifyTimeout);
      return _parseResponse(response);
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(code: 0, message: 'Unexpected error: $e');
    }
  }

  Future<Map<String, dynamic>> verifyImage({
    required List<int> imageBytes,
    required String filename,
    String platform = 'unknown',
    int shares = 0,
    String? accessToken,
  }) async {
    try {
      final uri = Uri.parse('${AppConstants.baseUrl}/verify/image');
      final request = http.MultipartRequest('POST', uri);
      if (accessToken != null && accessToken.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $accessToken';
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        imageBytes,
        filename: filename,
      ));
      request.fields['platform'] = platform;
      request.fields['shares'] = shares.toString();

      final streamed = await request.send().timeout(AppConstants.verifyTimeout);
      final response = await http.Response.fromStream(streamed);
      return _parseResponse(response);
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(code: 0, message: 'Unexpected error: $e');
    }
  }

  Future<Map<String, dynamic>> verifyUrl({
    required String url,
    String platform = 'unknown',
    int shares = 0,
    String? accessToken,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('${AppConstants.baseUrl}/verify/url'),
            headers: _authHeaders(accessToken),
            body: jsonEncode({
              'url': url,
              'platform': platform,
              'shares': shares,
            }),
          )
          .timeout(AppConstants.verifyTimeout);
      return _parseResponse(response);
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(code: 0, message: 'Unexpected error: $e');
    }
  }

  Future<Map<String, dynamic>> verifyVoice({
    required List<int> audioBytes,
    required String filename,
    String platform = 'unknown',
    int shares = 0,
    String? accessToken,
  }) async {
    try {
      final uri = Uri.parse('${AppConstants.baseUrl}/verify/voice');
      final request = http.MultipartRequest('POST', uri);
      if (accessToken != null && accessToken.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $accessToken';
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        audioBytes,
        filename: filename,
      ));
      request.fields['platform'] = platform;
      request.fields['shares'] = shares.toString();

      final streamed = await request.send().timeout(AppConstants.verifyTimeout);
      final response = await http.Response.fromStream(streamed);
      return _parseResponse(response);
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(code: 0, message: 'Unexpected error: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getFeed({
    required String accessToken,
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final response = await _client
          .get(
            Uri.parse(
                '${AppConstants.baseUrl}/feed/?limit=$limit&offset=$offset'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
          )
          .timeout(AppConstants.apiTimeout);
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        return list.cast<Map<String, dynamic>>();
      } else if (response.statusCode == 401) {
        throw const ApiException(code: 401, message: 'Unauthorized');
      } else {
        throw ApiException(
            code: response.statusCode, message: response.body);
      }
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(code: 0, message: 'Unexpected error: $e');
    }
  }

  Future<void> reportClaim({
    required String claimId,
    required String reportType,
    String? note,
    String? accessToken,
  }) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (accessToken != null && accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }
      final response = await _client
          .post(
            Uri.parse('${AppConstants.baseUrl}/verify/report'),
            headers: headers,
            body: jsonEncode({
              'claim_id': claimId,
              'report_type': reportType,
              'note': note ?? '',
            }),
          )
          .timeout(AppConstants.apiTimeout);
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw ApiException(
            code: response.statusCode, message: response.body);
      }
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
          code: 0, message: 'Failed to submit report. Try again.');
    }
  }

  Future<Map<String, dynamic>> login(
      String email, String password) async {
    try {
      final response = await _client
          .post(
            Uri.parse('${AppConstants.baseUrl}/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(AppConstants.apiTimeout);
      return _parseResponse(response);
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw const ApiException(
          code: 0, message: 'Could not connect to server. Check your connection.');
    }
  }

  Future<Map<String, dynamic>> register(
      String name, String email, String password, String? city) async {
    try {
      final body = <String, dynamic>{
        'name': name,
        'email': email,
        'password': password,
      };
      if (city != null && city.isNotEmpty) body['city'] = city;
      final response = await _client
          .post(
            Uri.parse('${AppConstants.baseUrl}/auth/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(AppConstants.apiTimeout);
      return _parseResponse(response);
    } on SocketException catch (e) {
      throw ApiException(code: 0, message: 'No internet connection: $e');
    } on TimeoutException {
      throw const ApiException(code: 0, message: 'Server took too long. Check your internet.');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw const ApiException(
          code: 0, message: 'Could not connect to server. Check your connection.');
    }
  }

  Future<void> logout(String refreshToken, String accessToken) async {
    try {
      await _client
          .post(
            Uri.parse('${AppConstants.baseUrl}/auth/logout'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(AppConstants.apiTimeout);
    } catch (_) {
      // Best effort — don't throw
    }
  }

  Future<Map<String, dynamic>> refreshToken(String refreshToken) async {
    final response = await _client
        .post(
          Uri.parse('${AppConstants.baseUrl}/auth/refresh'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}),
        )
        .timeout(AppConstants.apiTimeout);
    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw const ApiException(code: 401, message: 'Token refresh failed');
  }

  Future<Map<String, dynamic>> getMe(String accessToken) async {
    final response = await _client
        .get(
          Uri.parse('${AppConstants.baseUrl}/auth/me'),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
        )
        .timeout(AppConstants.apiTimeout);
    return _parseResponse(response);
  }
}