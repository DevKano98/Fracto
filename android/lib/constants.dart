// ========== FILE: lib/constants.dart ==========

enum InputType { text, image, url, voice }

enum VerdictBadgeSize { large, small }

class AppConstants {
  static const String baseUrl = "https://fracto-l151.onrender.com";
  // Local emulator:
  // static const String baseUrl = "http://10.0.2.2:8000";
  // ngrok fallback:
  // static const String baseUrl = "https://xxxx.ngrok-free.app";

  static const Duration apiTimeout = Duration(seconds: 60);
  static const Duration verifyTimeout = Duration(seconds: 90);
  static const int maxImageSizeBytes = 5 * 1024 * 1024; // 5MB

  // Secure storage keys
  static const String accessTokenKey = "fracta_access_token";
  static const String refreshTokenKey = "fracta_refresh_token";
  static const String userJsonKey = "fracta_user_json";

  // Voice assistant keys
  static const String assistantNameKey = 'fracta_assistant_name';
  static const String defaultAssistantName = 'Siri';
  static const String defaultWakePhrase = 'hey siri';

  // Platform options
  static const List<String> platforms = [
    "unknown",
    "whatsapp",
    "twitter",
    "instagram",
    "facebook",
  ];

  static const Map<String, String> platformLabels = {
    "unknown": "Unknown",
    "whatsapp": "WhatsApp",
    "twitter": "Twitter",
    "instagram": "Instagram",
    "facebook": "Facebook",
  };
}