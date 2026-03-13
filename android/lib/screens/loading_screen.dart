// ========== FILE: lib/screens/loading_screen.dart ==========

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../providers/claim_provider.dart';
import '../theme.dart';
import 'home_screen.dart';
import 'result_screen.dart';

class LoadingScreen extends StatefulWidget {
  final InputType inputType;
  final String? text;
  final List<int>? imageBytes;
  final String? imageFilename;
  final String? url;
  final List<int>? audioBytes;
  final String? audioFilename;
  final String platform;
  final int shares;
  final String? accessToken;

  const LoadingScreen({
    super.key,
    required this.inputType,
    this.text,
    this.imageBytes,
    this.imageFilename,
    this.url,
    this.audioBytes,
    this.audioFilename,
    required this.platform,
    required this.shares,
    this.accessToken,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _spinController;
  late Animation<double> _scaleAnim;
  int _stepIndex = 0;
  String? _error;
  Timer? _stepTimer;
  bool _hasNavigated = false;

  static const _steps = [
    'Detecting language...',
    'Searching 9 trusted sources...',
    'Consulting Gemini AI...',
    'Calculating risk score...',
    'Preparing your result...',
  ];

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _scaleAnim = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _spinController, curve: Curves.easeInOut),
    );

    _startStepCycle();
    WidgetsBinding.instance.addPostFrameCallback((_) => _submitClaim());
  }

  void _startStepCycle() {
    _stepTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(
          () => _stepIndex = (_stepIndex + 1) % _steps.length);
    });
  }

  Future<void> _submitClaim() async {
    if (!mounted) return;
    final claimProvider = context.read<ClaimProvider>();

    final claim = await claimProvider.verifyClaim(
      type: widget.inputType,
      text: widget.text,
      imageBytes: widget.imageBytes,
      imageFilename: widget.imageFilename,
      url: widget.url,
      audioBytes: widget.audioBytes,
      audioFilename: widget.audioFilename,
      platform: widget.platform,
      shares: widget.shares,
      accessToken: widget.accessToken,
    );

    if (!mounted || _hasNavigated) return;

    if (claim != null) {
      _hasNavigated = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ResultScreen(claim: claim)),
      );
    } else {
      final err = claimProvider.error ?? 'Verification failed. Please try again.';
      setState(() => _error = err);
    }
  }

  @override
  void dispose() {
    _spinController.dispose();
    _stepTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _error != null ? _buildError() : _buildLoading(),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Animated shield
        ScaleTransition(
          scale: _scaleAnim,
          child: RotationTransition(
            turns: _spinController,
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppColors.primary, width: 3),
                color: AppColors.primary.withOpacity(0.08),
              ),
              child: const Icon(
                Icons.shield_outlined,
                color: AppColors.primary,
                size: 40,
              ),
            ),
          ),
        ),
        const SizedBox(height: 36),
        const Text(
          'Analyzing claim...',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.onBackground,
          ),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Text(
            _steps[_stepIndex],
            key: ValueKey(_stepIndex),
            style: const TextStyle(
              color: AppColors.primary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 48),
        const Text(
          'This may take up to 10 seconds',
          style: TextStyle(color: AppColors.onSurface, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.verdictFalse.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.error_outline,
            color: AppColors.verdictFalse,
            size: 44,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Verification Failed',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.onBackground,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: AppColors.onSurface, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 36),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const HomeScreen()),
              (_) => false,
            );
          },
          icon: const Icon(Icons.arrow_back),
          label: const Text('Go Back'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () {
            setState(() => _error = null);
            _submitClaim();
          },
          style: TextButton.styleFrom(
              foregroundColor: AppColors.primary),
          child: const Text('Try Again'),
        ),
      ],
    );
  }
}