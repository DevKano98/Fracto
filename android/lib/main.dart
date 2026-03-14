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
import 'services/background_service.dart';
import 'services/floating_bubble_service.dart';
import 'services/native_settings_service.dart';
import 'services/voice_assistant_service.dart';
import 'theme.dart';

// ── Overlay entry point is in overlay_bubble.dart (single source of truth) ──

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
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  // Set up notification channels + background service config.
  // The service process itself starts from HomeScreen after permissions.
  await FractaBackgroundService.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ClaimProvider()),
        ChangeNotifierProvider(create: (_) => VoiceAssistantService()),
      ],
      child: const FractaApp(),
    ),
  );
}

/// Listens for app resume to show floating bubble after user grants overlay permission.
class _FractaAppWithOverlayResume extends StatefulWidget {
  final Widget child;

  const _FractaAppWithOverlayResume({required this.child});

  @override
  State<_FractaAppWithOverlayResume> createState() => _FractaAppWithOverlayResumeState();
}

class _FractaAppWithOverlayResumeState extends State<_FractaAppWithOverlayResume>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      FloatingBubbleService.tryShowBubbleAfterResume(
        startBackgroundService: FractaBackgroundService.start,
      );
      // If bubble is visible but projection is dead, re-request screen capture
      _reRequestScreenCaptureIfNeeded();
    }
  }

  Future<void> _reRequestScreenCaptureIfNeeded() async {
    try {
      final bubbleVisible = await FloatingBubbleService.isBubbleVisible;
      if (!bubbleVisible) return;
      final projectionAlive = await NativeSettingsService.isProjectionAlive();
      if (!projectionAlive) {
        debugPrint('[FRACTA-BUBBLE] App resumed — bubble visible but projection dead, re-requesting screen capture');
        // Small delay so the app fully resumes before showing system dialog
        await Future<void>.delayed(const Duration(milliseconds: 800));
        NativeSettingsService.requestScreenCapturePermission();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class FractaApp extends StatelessWidget {
  const FractaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return _FractaAppWithOverlayResume(
      child: MaterialApp(
        title: 'Fracta',
        theme: AppTheme.lightTheme,
        home: const SplashScreen(),
        debugShowCheckedModeBanner: false,
        onGenerateRoute: (settings) {
          return MaterialPageRoute(
            builder: (context) {
              final auth = Provider.of<AuthProvider>(context, listen: false);
              final bool isPublicRoute =
                  settings.name == '/login' ||
                  settings.name == '/register' ||
                  settings.name == '/';
              if (!auth.isLoggedIn && !isPublicRoute) {
                return const LoginScreen();
              }
              return switch (settings.name) {
              '/home' => const HomeScreen(),
              '/login' => const LoginScreen(),
              '/register' => const RegisterScreen(),
              '/history' => const HistoryScreen(),
              '/settings' => const SettingsScreen(),
                _ => const SplashScreen(),
              };
            },
          );
        },
      ),
    );
  }
}