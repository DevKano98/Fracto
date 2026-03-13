// ========== FILE: lib/services/background_service.dart ==========
//
// This is the heart of Fracta.
//
// Flow:
//   1. On app launch → FractaBackgroundService.initialize()
//   2. Service starts a persistent foreground notification ("Fracta is watching")
//   3. FloatingBubble appears over all apps (draw-over-apps permission)
//   4. User taps bubble → QuickCaptureScreen slides up as overlay
//   5. User speaks / pastes text / shares from WhatsApp
//   6. Service calls FastAPI, gets verdict
//   7. OverlayResultScreen shows verdict as overlay card (no need to open app)
//   8. If app IS open, result_screen is pushed normally
//
// Communication between isolates uses flutter_background_service's
// invoke/on(String event) message bus.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';

// ── Notification channel IDs ───────────────────────────────────────────────
const _kForegroundChannelId = 'fracta_foreground';
const _kForegroundChannelName = 'Fracta Active';
const _kResultChannelId = 'fracta_results';
const _kResultChannelName = 'Fracta Verdicts';
const _kForegroundNotifId = 1;

// ── Event names on the service bus ────────────────────────────────────────
class FractaEvent {
  static const String verifyText   = 'verify_text';
  static const String verifyVoice  = 'verify_voice';
  static const String verifyUrl    = 'verify_url';
  static const String verdictReady = 'verdict_ready';
  static const String verdictError = 'verdict_error';
  static const String shareReceived = 'share_received';
  static const String stopService  = 'stop_service';
  static const String ping         = 'ping';
}

class FractaBackgroundService {
  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static final FlutterLocalNotificationsPlugin _notifs =
      FlutterLocalNotificationsPlugin();

  /// Call once from main() before runApp.
  static Future<void> initialize() async {
    // ── Notification channels ──────────────────────────────────────────
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifs.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: _onNotifTap,
    );

    await _notifs
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _kForegroundChannelId,
            _kForegroundChannelName,
            description: 'Keeps Fracta running in background',
            importance: Importance.low,
            playSound: false,
            enableVibration: false,
          ),
        );

    await _notifs
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _kResultChannelId,
            _kResultChannelName,
            description: 'Misinformation verdict notifications',
            importance: Importance.high,
          ),
        );

    // ── Configure background service ──────────────────────────────────
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: _kForegroundChannelId,
        initialNotificationTitle: 'Fracta',
        initialNotificationContent: 'Tap to fact-check anything',
        foregroundServiceNotificationId: _kForegroundNotifId,
        foregroundServiceTypes: const [AndroidForegroundType.microphone],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: _onServiceStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  /// Start the background service (call after permissions granted).
  static Future<void> start() async {
    final running = await _service.isRunning();
    if (!running) await _service.startService();
  }

  /// Stop the service explicitly (e.g., user disables in settings).
  static Future<void> stop() async {
    final s = FlutterBackgroundService();
    s.invoke(FractaEvent.stopService);
  }

  static Future<bool> get isRunning => _service.isRunning();

  /// Send a text claim to the background isolate for verification.
  static void sendTextForVerification(String text, {String platform = 'unknown'}) {
    _service.invoke(FractaEvent.verifyText, {
      'text': text,
      'platform': platform,
    });
  }

  /// Send a URL for verification.
  static void sendUrlForVerification(String url, {String platform = 'unknown'}) {
    _service.invoke(FractaEvent.verifyUrl, {
      'url': url,
      'platform': platform,
    });
  }

  /// Listen for verdicts coming back from the background isolate.
  static Stream<Map<String, dynamic>?> get verdictStream =>
      _service.on(FractaEvent.verdictReady);

  /// Listen for errors.
  static Stream<Map<String, dynamic>?> get errorStream =>
      _service.on(FractaEvent.verdictError);

  // ── iOS background handler (required by package) ───────────────────
  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  // ── Notification tap ───────────────────────────────────────────────
  static void _onNotifTap(NotificationResponse response) {
    // Handled by the app via a GlobalKey navigator or shared_preferences flag
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TOP-LEVEL entry point — runs in a separate Dart isolate
// MUST be a top-level function annotated with @pragma('vm:entry-point')
// ═══════════════════════════════════════════════════════════════════════════
@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final FlutterLocalNotificationsPlugin notifs =
      FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings androidInit =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifs.initialize(
      const InitializationSettings(android: androidInit));

  // Update foreground notification to show "ready" state
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'Fracta is active',
      content: 'Tap to fact-check • Share from any app',
    );
  }

  // ── Listen: verify text ────────────────────────────────────────────
  service.on(FractaEvent.verifyText).listen((event) async {
    if (event == null) return;
    final text = event['text'] as String? ?? '';
    final platform = event['platform'] as String? ?? 'unknown';
    if (text.isEmpty) return;

    await _updateNotif(notifs, 'Checking claim...', _truncate(text, 60));

    try {
      final result = await _callVerifyText(text, platform);
      service.invoke(FractaEvent.verdictReady, result);
      await _showVerdictNotif(notifs, result);
      await _updateNotif(notifs, 'Fracta is active', 'Tap to fact-check • Share from any app');
    } catch (e) {
      service.invoke(FractaEvent.verdictError, {'message': e.toString()});
      await _updateNotif(notifs, 'Fracta is active', 'Tap to fact-check • Share from any app');
    }
  });

  // ── Listen: verify URL ─────────────────────────────────────────────
  service.on(FractaEvent.verifyUrl).listen((event) async {
    if (event == null) return;
    final url = event['url'] as String? ?? '';
    final platform = event['platform'] as String? ?? 'unknown';
    if (url.isEmpty) return;

    await _updateNotif(notifs, 'Checking URL...', _truncate(url, 60));

    try {
      final result = await _callVerifyUrl(url, platform);
      service.invoke(FractaEvent.verdictReady, result);
      await _showVerdictNotif(notifs, result);
      await _updateNotif(notifs, 'Fracta is active', 'Tap to fact-check • Share from any app');
    } catch (e) {
      service.invoke(FractaEvent.verdictError, {'message': e.toString()});
      await _updateNotif(notifs, 'Fracta is active', 'Tap to fact-check • Share from any app');
    }
  });

  // ── Listen: stop ───────────────────────────────────────────────────
  service.on(FractaEvent.stopService).listen((_) {
    service.stopSelf();
  });

  // ── Keepalive ping every 20s ───────────────────────────────────────
  Timer.periodic(const Duration(seconds: 20), (_) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }
  });
}

// ── Internal HTTP helpers (run inside isolate, no BuildContext) ────────────

Future<Map<String, dynamic>> _callVerifyText(
    String text, String platform) async {
  final token = await _getStoredToken();
  final uri = Uri.parse('${AppConstants.baseUrl}/verify/text');
  final headers = <String, String>{'Content-Type': 'application/json'};
  if (token != null) headers['Authorization'] = 'Bearer $token';

  // Use dart:io HttpClient inside isolate (http package needs main isolate setup)
  final client = _IsolateHttpClient();
  final body = jsonEncode({
    'claim_text': text,
    'platform': platform,
    'shares': 0,
  });
  final response = await client.post(uri.toString(), headers, body);
  if (response['status'] == 200 || response['status'] == 201) {
    return jsonDecode(response['body'] as String) as Map<String, dynamic>;
  }
  throw Exception('API error ${response['status']}: ${response['body']}');
}

Future<Map<String, dynamic>> _callVerifyUrl(
    String url, String platform) async {
  final token = await _getStoredToken();
  final uri = Uri.parse('${AppConstants.baseUrl}/verify/url');
  final headers = <String, String>{'Content-Type': 'application/json'};
  if (token != null) headers['Authorization'] = 'Bearer $token';

  final client = _IsolateHttpClient();
  final body = jsonEncode({
    'url': url,
    'platform': platform,
    'shares': 0,
  });
  final response = await client.post(uri.toString(), headers, body);
  if (response['status'] == 200 || response['status'] == 201) {
    return jsonDecode(response['body'] as String) as Map<String, dynamic>;
  }
  throw Exception('API error ${response['status']}: ${response['body']}');
}

Future<String?> _getStoredToken() async {
  try {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    return await storage.read(key: AppConstants.accessTokenKey);
  } catch (_) {
    return null;
  }
}

Future<void> _updateNotif(
    FlutterLocalNotificationsPlugin notifs, String title, String body) async {
  await notifs.show(
    _kForegroundNotifId,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _kForegroundChannelId,
        _kForegroundChannelName,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        playSound: false,
        enableVibration: false,
        icon: '@mipmap/ic_launcher',
      ),
    ),
  );
}

Future<void> _showVerdictNotif(
    FlutterLocalNotificationsPlugin notifs, Map<String, dynamic> result) async {
  final verdict = result['llm_verdict'] as String? ?? 'UNVERIFIED';
  final claim = result['extracted_claim'] as String? ??
      result['raw_text'] as String? ?? '';
  final risk = result['risk_level'] as String? ?? '';

  final emoji = switch (verdict.toUpperCase()) {
    'TRUE' => '✅',
    'FALSE' => '❌',
    'MISLEADING' => '⚠️',
    _ => '❓',
  };

  await notifs.show(
    2,
    '$emoji Verdict: $verdict  •  $risk RISK',
    _truncate(claim, 100),
    NotificationDetails(
      android: AndroidNotificationDetails(
        _kResultChannelId,
        _kResultChannelName,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        styleInformation: BigTextStyleInformation(_truncate(claim, 300)),
      ),
    ),
  );
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

// ── Minimal HTTP client safe to use in a background isolate ───────────────
class _IsolateHttpClient {
  Future<Map<String, dynamic>> post(
      String url, Map<String, String> headers, String body) async {
    final uri = Uri.parse(url);
    final socket = await _connect(uri);
    final request = StringBuffer();
    request.write('POST ${uri.path}${uri.query.isNotEmpty ? '?${uri.query}' : ''} HTTP/1.1\r\n');
    request.write('Host: ${uri.host}:${uri.port}\r\n');
    for (final e in headers.entries) {
      request.write('${e.key}: ${e.value}\r\n');
    }
    final bodyBytes = utf8.encode(body);
    request.write('Content-Length: ${bodyBytes.length}\r\n');
    request.write('Connection: close\r\n');
    request.write('\r\n');

    socket.add(utf8.encode(request.toString()));
    socket.add(bodyBytes);
    await socket.flush();

    final response = await socket.fold<List<int>>(
      [],
      (prev, element) => prev..addAll(element),
    );
    await socket.close();

    final raw = utf8.decode(response, allowMalformed: true);
    final headerEnd = raw.indexOf('\r\n\r\n');
    final headerSection = headerEnd >= 0 ? raw.substring(0, headerEnd) : raw;
    final responseBody = headerEnd >= 0 ? raw.substring(headerEnd + 4) : '';
    final statusLine = headerSection.split('\r\n').first;
    final statusCode = int.tryParse(statusLine.split(' ')[1]) ?? 0;

    return {'status': statusCode, 'body': responseBody};
  }

  Future<dynamic> _connect(Uri uri) async {
    if (uri.scheme == 'https') {
      return await SecureSocket.connect(uri.host, uri.port,
          timeout: AppConstants.verifyTimeout);
    }
    return await Socket.connect(uri.host, uri.port,
        timeout: AppConstants.verifyTimeout);
  }
}