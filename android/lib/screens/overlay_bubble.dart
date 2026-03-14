// ========== FILE: lib/screens/overlay_bubble.dart ==========
//
// This widget is rendered INSIDE the overlay window (separate from the main
// Flutter app). It shows the pulsing Fracta bubble. When tapped it sends
// a message to the main app to open the quick capture sheet.
//
// Entry point: overlayMain() — registered in main.dart

import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../theme.dart';

// Top-level entry for the overlay isolate
@pragma('vm:entry-point')
void overlayMain() {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OverlayBubbleApp());
}

class _OverlayBubbleApp extends StatelessWidget {
  const _OverlayBubbleApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const OverlayBubbleWidget(),
    );
  }
}

class OverlayBubbleWidget extends StatefulWidget {
  const OverlayBubbleWidget({super.key});

  @override
  State<OverlayBubbleWidget> createState() => _OverlayBubbleWidgetState();
}

class _OverlayBubbleWidgetState extends State<OverlayBubbleWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  bool _isProcessing = false;
  String _statusText = '';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Listen for messages from main app (e.g., "processing", verdict)
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is Map) {
        setState(() {
          _isProcessing = data['processing'] == true;
          _statusText = data['status'] as String? ?? '';
        });
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _onTap() {
    // Send tap event to main app
    FlutterOverlayWindow.shareData({'action': 'open_capture'});
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _onTap,
        child: ScaleTransition(
          scale: _isProcessing ? _pulseAnim : const AlwaysStoppedAnimation(1.0),
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isProcessing
                  ? AppColors.riskMedium
                  : AppColors.primary,
              boxShadow: [
                BoxShadow(
                  color: (_isProcessing
                          ? AppColors.riskMedium
                          : AppColors.primary)
                      .withOpacity(0.5),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isProcessing ? Icons.hourglass_top_rounded : Icons.shield_rounded,
                  color: Colors.white,
                  size: 26,
                ),
                if (_statusText.isNotEmpty)
                  Text(
                    _statusText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 7,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}