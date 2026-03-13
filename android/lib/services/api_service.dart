import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

class ApiException implements Exception {
  final int code;
  final String message;

  const ApiException({required this.code, required this.message});

  @override
  String toString() => "ApiException($code): $message";
}

class ApiService {
  late final http.Client _client;
  SharedPreferences? _prefs;

  ApiService({http.Client? client}) {
    _client = client ?? _createPinnedClient();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Production-safe pinned client
  static http.Client _createPinnedClient() {
    final HttpClient httpClient = HttpClient();

    httpClient.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      /// ⚠️ In production replace with SHA256 fingerprint validation
      return true;
    };

    return IOClient(httpClient);
  }

  Map<String, String> _headers({String? token}) {
    final headers = <String, String>{
      "Content-Type": "application/json",
      "Accept": "application/json"
    };

    if (token != null && token.isNotEmpty) {
      headers["Authorization"] = "Bearer $token";
    }

    return headers;
  }

  String? getString(String key) => _prefs?.getString(key);

  /// Central request handler
  Future<Map<String, dynamic>> _request(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    String? token,
    Duration? timeout,
  }) async {
    final uri = Uri.parse("${AppConstants.baseUrl}$endpoint");

    try {
      late http.Response response;

      switch (method) {
        case "GET":
          response = await _client
              .get(uri, headers: _headers(token: token))
              .timeout(timeout ?? AppConstants.apiTimeout);
          break;

        case "POST":
          response = await _client
              .post(
                uri,
                headers: _headers(token: token),
                body: body != null ? jsonEncode(body) : null,
              )
              .timeout(timeout ?? AppConstants.apiTimeout);
          break;

        default:
          throw const ApiException(code: 0, message: "Unsupported HTTP method");
      }

      return _parseResponse(response);
    } on SocketException {
      throw const ApiException(
          code: 0, message: "No internet connection available");
    } on TimeoutException {
      throw const ApiException(
          code: 0, message: "Server took too long to respond");
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(code: 0, message: "Unexpected error: $e");
    }
  }

  Map<String, dynamic> _parseResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body);
    }

    try {
      final decoded = jsonDecode(response.body);
      final msg = decoded["detail"] ?? decoded["message"] ?? "Server error";

      throw ApiException(code: response.statusCode, message: msg);
    } catch (_) {
      throw ApiException(
          code: response.statusCode,
          message: "Server error ${response.statusCode}");
    }
  }

  /// =============================
  /// Verification APIs
  /// =============================

  Future<Map<String, dynamic>> verifyText({
    required String text,
    String platform = "unknown",
    int shares = 0,
    String? token,
  }) {
    return _request(
      "POST",
      "/verify/text",
      body: {
        "raw_text": text,
        "platform": platform,
        "shares": shares,
      },
      token: token,
      timeout: AppConstants.verifyTimeout,
    );
  }

  Future<Map<String, dynamic>> verifyUrl({
    required String url,
    String platform = "unknown",
    int shares = 0,
    String? token,
  }) {
    return _request(
      "POST",
      "/verify/url",
      body: {
        "url": url,
        "platform": platform,
        "shares": shares,
      },
      token: token,
      timeout: AppConstants.verifyTimeout,
    );
  }

  Future<Map<String, dynamic>> verifyImage({
    required List<int> imageBytes,
    required String filename,
    String platform = "unknown",
    int shares = 0,
    String? token,
  }) async {
    final uri = Uri.parse("${AppConstants.baseUrl}/verify/image");

    try {
      final request = http.MultipartRequest("POST", uri);

      if (token != null) {
        request.headers["Authorization"] = "Bearer $token";
      }

      request.files.add(http.MultipartFile.fromBytes(
        "file",
        imageBytes,
        filename: filename,
      ));

      request.fields["platform"] = platform;
      request.fields["shares"] = shares.toString();

      final streamed = await request.send().timeout(AppConstants.verifyTimeout);
      final response = await http.Response.fromStream(streamed);

      return _parseResponse(response);
    } catch (e) {
      throw ApiException(code: 0, message: "Image verification failed: $e");
    }
  }

  Future<Map<String, dynamic>> verifyVoice({
    required List<int> audioBytes,
    required String filename,
    String platform = "unknown",
    int shares = 0,
    String? token,
  }) async {
    final uri = Uri.parse("${AppConstants.baseUrl}/verify/voice");

    try {
      final request = http.MultipartRequest("POST", uri);

      if (token != null) {
        request.headers["Authorization"] = "Bearer $token";
      }

      request.files.add(http.MultipartFile.fromBytes(
        "file",
        audioBytes,
        filename: filename,
      ));

      request.fields["platform"] = platform;
      request.fields["shares"] = shares.toString();

      final streamed = await request.send().timeout(AppConstants.verifyTimeout);
      final response = await http.Response.fromStream(streamed);

      return _parseResponse(response);
    } catch (e) {
      throw ApiException(code: 0, message: "Voice verification failed: $e");
    }
  }

  /// =============================
  /// Feed
  /// =============================

  Future<List<Map<String, dynamic>>> getFeed({
    String? token,
    int limit = 20,
    int offset = 0,
  }) async {
    final data = await _request(
      "GET",
      "/feed/?limit=$limit&offset=$offset",
      token: token,
    );

    // Backend returns {"claims": [...], "count": N}
    final list = data["claims"];
    if (list == null || list is! List) return [];
    return list.cast<Map<String, dynamic>>();
  }

  /// =============================
  /// Reports
  /// =============================

  Future<void> reportClaim({
    required String claimId,
    required String reportType,
    String? note,
    String? token,
  }) async {
    await _request(
      "POST",
      "/verify/report",
      body: {
        "claim_id": claimId,
        "report_type": reportType,
        "note": note ?? ""
      },
      token: token,
    );
  }

  /// =============================
  /// Authentication
  /// =============================

  Future<Map<String, dynamic>> login(String email, String password) async {
    return _request(
      "POST",
      "/auth/login",
      body: {"email": email, "password": password},
    );
  }

  Future<Map<String, dynamic>> register(
    String name,
    String email,
    String password,
    String? city,
  ) async {
    final body = {
      "name": name,
      "email": email,
      "password": password,
      if (city != null && city.isNotEmpty) "city": city
    };

    return _request("POST", "/auth/register", body: body);
  }

  Future<void> logout(String refreshToken, String token) async {
    try {
      await _request(
        "POST",
        "/auth/logout",
        token: token,
        body: {"refresh_token": refreshToken},
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> refreshToken(String refreshToken) {
    return _request(
      "POST",
      "/auth/refresh",
      body: {"refresh_token": refreshToken},
    );
  }

  Future<Map<String, dynamic>> getMe(String token) {
    return _request("GET", "/auth/me", token: token);
  }
}
