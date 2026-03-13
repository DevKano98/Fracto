// ========== FILE: lib/services/background_service.dart ==========

import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants.dart';

const _foregroundChannelId = "fracta_foreground";
const _foregroundChannelName = "Fracta Active";

const _resultChannelId = "fracta_results";
const _resultChannelName = "Fracta Verdicts";

const _foregroundNotifId = 1;

class FractaEvent {
  static const verifyText = "verify_text";
  static const verifyUrl = "verify_url";

  static const verdictReady = "verdict_ready";
  static const verdictError = "verdict_error";

  static const stopService = "stop_service";
}

class FractaBackgroundService {
  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  /// ─────────────────────────────────────────────
  /// Initialize service (call from main)
  /// ─────────────────────────────────────────────
  static Future<void> initialize() async {
    const androidInit = AndroidInitializationSettings("@mipmap/ic_launcher");

    await _notifications.initialize(
      const InitializationSettings(android: androidInit),
    );

    final androidNotif = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await androidNotif?.createNotificationChannel(
      const AndroidNotificationChannel(
        _foregroundChannelId,
        _foregroundChannelName,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );

    await androidNotif?.createNotificationChannel(
      const AndroidNotificationChannel(
        _resultChannelId,
        _resultChannelName,
        importance: Importance.high,
      ),
    );

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _foregroundChannelId,
        initialNotificationTitle: "Fracta",
        initialNotificationContent: "Tap to fact-check anything",
        foregroundServiceNotificationId: _foregroundNotifId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: _onServiceStart,
      ),
    );
  }

  static Future<bool> get isRunning async => await _service.isRunning();

  static Future<void> start() async {
    if (!await _service.isRunning()) {
      await _service.startService();
    }
  }

  static Future<void> stop() async {
    _service.invoke(FractaEvent.stopService);
  }

  static Stream<Map<String, dynamic>?> get verdictStream =>
      _service.on(FractaEvent.verdictReady).map(
            (event) => event == null ? null : Map<String, dynamic>.from(event),
          );

  static Stream<Map<String, dynamic>?> get errorStream =>
      _service.on(FractaEvent.verdictError);

  static void sendTextForVerification(String text,
      {String platform = "unknown"}) {
    _service.invoke(FractaEvent.verifyText, {
      "text": text,
      "platform": platform,
    });
  }

  static void sendUrlForVerification(String url,
      {String platform = "unknown"}) {
    _service.invoke(FractaEvent.verifyUrl, {
      "url": url,
      "platform": platform,
    });
  }
}

@pragma("vm:entry-point")
void _onServiceStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final notifications = FlutterLocalNotificationsPlugin();

  const androidInit = AndroidInitializationSettings("@mipmap/ic_launcher");

  await notifications
      .initialize(const InitializationSettings(android: androidInit));

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: "Fracta is active",
      content: "Tap to fact-check anything",
    );
  }

  final storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? token;
  DateTime? tokenExpiry;

  Future<String?> getToken() async {
    if (token != null &&
        tokenExpiry != null &&
        DateTime.now().isBefore(tokenExpiry!)) {
      return token;
    }

    token = await storage.read(key: AppConstants.accessTokenKey);

    tokenExpiry = DateTime.now().add(const Duration(minutes: 30));

    return token;
  }

  service.on(FractaEvent.verifyText).listen((event) async {
    if (event == null) return;

    final text = event["text"] ?? "";
    final platform = event["platform"] ?? "unknown";

    if (text.isEmpty) return;

    try {
      await _updateNotification(notifications, "Checking claim...", text);

      final result = await _verifyText(text, platform, await getToken());

      service.invoke(FractaEvent.verdictReady, result);

      await _showVerdictNotification(notifications, result);

      await _updateNotification(
          notifications, "Fracta is active", "Tap to fact-check anything");
    } catch (e) {
      service.invoke(FractaEvent.verdictError, {"message": e.toString()});
    }
  });

  service.on(FractaEvent.verifyUrl).listen((event) async {
    if (event == null) return;

    final url = event["url"] ?? "";
    final platform = event["platform"] ?? "unknown";

    if (url.isEmpty) return;

    try {
      await _updateNotification(notifications, "Checking URL...", url);

      final result = await _verifyUrl(url, platform, await getToken());

      service.invoke(FractaEvent.verdictReady, result);

      await _showVerdictNotification(notifications, result);

      await _updateNotification(
          notifications, "Fracta is active", "Tap to fact-check anything");
    } catch (e) {
      service.invoke(FractaEvent.verdictError, {"message": e.toString()});
    }
  });

  service.on(FractaEvent.stopService).listen((_) {
    service.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 20), (_) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }
  });
}

Future<Map<String, dynamic>> _verifyText(
    String text, String platform, String? token) async {
  final uri = Uri.parse("${AppConstants.baseUrl}/verify/text");

  final headers = {"Content-Type": "application/json"};

  if (token != null) headers["Authorization"] = "Bearer $token";

  final response = await http
      .post(
        uri,
        headers: headers,
        body: jsonEncode({
          "raw_text": text,
          "platform": platform,
          "shares": 0,
        }),
      )
      .timeout(AppConstants.verifyTimeout);

  if (response.statusCode == 200 || response.statusCode == 201) {
    return jsonDecode(response.body);
  }

  throw Exception("API error ${response.statusCode}");
}

Future<Map<String, dynamic>> _verifyUrl(
    String url, String platform, String? token) async {
  final uri = Uri.parse("${AppConstants.baseUrl}/verify/url");

  final headers = {"Content-Type": "application/json"};

  if (token != null) headers["Authorization"] = "Bearer $token";

  final response = await http
      .post(
        uri,
        headers: headers,
        body: jsonEncode({
          "url": url,
          "platform": platform,
          "shares": 0,
        }),
      )
      .timeout(AppConstants.verifyTimeout);

  if (response.statusCode == 200 || response.statusCode == 201) {
    return jsonDecode(response.body);
  }

  throw Exception("API error ${response.statusCode}");
}

Future<void> _updateNotification(FlutterLocalNotificationsPlugin notifications,
    String title, String body) async {
  await notifications.show(
    _foregroundNotifId,
    title,
    _truncate(body, 60),
    NotificationDetails(
      android: AndroidNotificationDetails(
        _foregroundChannelId,
        _foregroundChannelName,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        playSound: false,
        enableVibration: false,
      ),
    ),
  );
}

Future<void> _showVerdictNotification(
    FlutterLocalNotificationsPlugin notifications,
    Map<String, dynamic> result) async {
  final verdict = result["llm_verdict"] ?? "UNVERIFIED";
  final claim = result["extracted_claim"] ?? result["raw_text"] ?? "";

  final emoji = switch (verdict.toString().toUpperCase()) {
    "TRUE" => "✅",
    "FALSE" => "❌",
    "MISLEADING" => "⚠️",
    _ => "❓"
  };

  await notifications.show(
    DateTime.now().millisecondsSinceEpoch % 100000,
    "$emoji Verdict: $verdict",
    _truncate(claim, 100),
    NotificationDetails(
      android: AndroidNotificationDetails(
        _resultChannelId,
        _resultChannelName,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(_truncate(claim, 300)),
      ),
    ),
  );
}

String _truncate(String text, int max) {
  final runes = text.runes;

  if (runes.length <= max) return text;

  return "${String.fromCharCodes(runes.take(max))}…";
}
