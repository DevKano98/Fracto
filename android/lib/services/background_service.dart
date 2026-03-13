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
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
        autoStart: false,
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
      _service.on(FractaEvent.verdictReady).map((data) {
        if (data == null) return null;
        // Point 1: Ensure we handle potential wrapping or typing mismatches
        return Map<String, dynamic>.from(data);
      });

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
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  String? _memoizedToken;
  DateTime? _tokenExpiry;

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
    if (event == null || !event.containsKey('text')) return;
    final text = event['text'] as String? ?? '';
    final platform = event['platform'] as String? ?? 'unknown';
    if (text.isEmpty) return;

    await _updateNotif(notifs, 'Checking claim...', _truncate(text, 60));

    try {
      // Refresh token if needed or not exists
      if (_memoizedToken == null || 
          _tokenExpiry == null || 
          DateTime.now().isAfter(_tokenExpiry!)) {
        _memoizedToken = await _getStoredToken();
        _tokenExpiry = DateTime.now().add(const Duration(minutes: 30));
      }

      final result = await _callVerifyText(text, platform, _memoizedToken);
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
      // Refresh token if needed or not exists
      if (_memoizedToken == null || 
          _tokenExpiry == null || 
          DateTime.now().isAfter(_tokenExpiry!)) {
        _memoizedToken = await _getStoredToken();
        _tokenExpiry = DateTime.now().add(const Duration(minutes: 30));
      }

      final result = await _callVerifyUrl(url, platform, _memoizedToken);
      service.invoke(FractaEvent.verdictReady, result);
      await _showVerdictNotif(notifs, result);
      await _updateNotif(notifs, 'Fracta is active', 'Tap to fact-check • Share from any app');
    } catch (e) {
      service.invoke(FractaEvent.verdictError, {'message': e.toString()});
      await _updateNotif(notifs, 'Fracta is active', 'Tap to fact-check • Share from any app');
    }
  });

  // ── Keepalive ping every 20s ───────────────────────────────────────
  final pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }
  });

  // ── Listen: stop ───────────────────────────────────────────────────
  service.on(FractaEvent.stopService).listen((_) {
    pingTimer.cancel();
    service.stopSelf();
  });
}

// ── Internal HTTP helpers (run inside isolate, no BuildContext) ────────────

Future<Map<String, dynamic>> _callVerifyText(
    String text, String platform, String? memoizedToken) async {
  final token = memoizedToken ?? await _getStoredToken();
  final uri = Uri.parse('${AppConstants.baseUrl}/verify/text');
  final headers = <String, String>{'Content-Type': 'application/json'};
  if (token != null) headers['Authorization'] = 'Bearer $token';

  try {
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'raw_text': text, // Point 1: Match API contract
        'platform': platform,
        'shares': 0,
      }),
    ).timeout(AppConstants.verifyTimeout);

    if (response.statusCode == 200 || response.statusCode == 201) {
      // Point 4: JSON decoding safety
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('API error ${response.statusCode}: ${response.body}');
  } on FormatException catch (e) {
    throw Exception('Invalid JSON response: $e');
  } catch (e) {
    rethrow;
  }
}

Future<Map<String, dynamic>> _callVerifyUrl(
    String url, String platform, String? memoizedToken) async {
  final token = memoizedToken ?? await _getStoredToken();
  final uri = Uri.parse('${AppConstants.baseUrl}/verify/url');
  final headers = <String, String>{'Content-Type': 'application/json'};
  if (token != null) headers['Authorization'] = 'Bearer $token';

  try {
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'url': url,
        'platform': platform,
        'shares': 0,
      }),
    ).timeout(AppConstants.verifyTimeout);

    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('API error ${response.statusCode}: ${response.body}');
  } on FormatException catch (e) {
    throw Exception('Invalid JSON response: $e');
  } catch (e) {
    rethrow;
  }
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
    DateTime.now().millisecondsSinceEpoch % 100000 + 10, // Point 10: Unique ID
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

String _truncate(String s, int max) {
  // Point 5: Multi-byte safe truncate using runes
  final runes = s.runes;
  if (runes.length <= max) return s;
  return '${String.fromCharCodes(runes.take(max))}…';
}