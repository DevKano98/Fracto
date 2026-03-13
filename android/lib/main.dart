// ========== FILE: lib/main.dart ==========
//
// Boot sequence:
//   1. Initialize background service (registers notification channels,
//      configures auto-start — does NOT start the process yet)
//   2. runApp with providers
//   3. After login, HomeScreen starts the service + share handler

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/claim_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/overlay_bubble.dart';
import 'services/background_service.dart';
import 'services/voice_assistant_service.dart';
import 'theme.dart';

// ── Overlay entry point ────────────────────────────────────────────────────
// flutter_overlay_window calls this top-level function (in its own isolate)
// to render the floating bubble. Must be annotated and top-level.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OverlayBubbleApp());
}

class _OverlayBubbleApp extends StatelessWidget {
  const _OverlayBubbleApp();
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const OverlayBubbleWidget(),
      );
}

// ── Main entry point ───────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Set up notification channels + background service config.
  // The service process itself starts from HomeScreen after permissions.
  await FractaBackgroundService.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ClaimProvider()),        ChangeNotifierProvider(create: (_) => VoiceAssistantService()),      ],
      child: const FractaApp(),
    ),
  );
}

class FractaApp extends StatelessWidget {
  const FractaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fracta',
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
      debugShowCheckedModeBanner: false,
      routes: {
        '/home':     (_) => const HomeScreen(),
        '/login':    (_) => const LoginScreen(),
        '/register': (_) => const RegisterScreen(),
        '/history':  (_) => const HistoryScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }
}