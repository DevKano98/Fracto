// ========== FILE: lib/screens/assistant_overlay_screen.dart ==========
//
// Voice assistant overlay: Idle | Wake word detected | Listening | Processing | Speaking | Result
// Modern card design with rounded corners, soft shadows, large mic animation, smooth transitions.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import '../services/voice_assistant_service.dart';
import '../theme.dart';
import '../widgets/verdict_badge.dart';
import 'result_screen.dart';

class AssistantOverlayScreen extends StatefulWidget {
  const AssistantOverlayScreen({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AssistantOverlayScreen(),
    );
  }

  @override
  State<AssistantOverlayScreen> createState() => _AssistantOverlayScreenState();
}

class _AssistantOverlayScreenState extends State<AssistantOverlayScreen> {
  static BoxDecoration get _cardDecoration => BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 20,
            spreadRadius: 0,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: AppColors.primary.withOpacity(0.08),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 4),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Consumer<VoiceAssistantService>(
      builder: (context, assistant, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.95, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
                ),
                child: child,
              ),
            );
          },
          child: _buildContent(assistant),
        );
      },
    );
  }

  Widget _buildContent(VoiceAssistantService assistant) {
    switch (assistant.state) {
      case VoiceAssistantState.idle:
        return const SizedBox.shrink(key: ValueKey('idle'));
      case VoiceAssistantState.woken:
        return _buildWokenCard();
      case VoiceAssistantState.listening:
        return _buildListeningCard();
      case VoiceAssistantState.processing:
        return _buildProcessingCard();
      case VoiceAssistantState.speaking:
        return _buildSpeakingCard(assistant.lastClaim);
      case VoiceAssistantState.error:
        return _buildErrorCard();
    }
  }

  Widget _buildWokenCard() {
    return Container(
      key: const ValueKey('woken'),
      margin: const EdgeInsets.all(20),
      decoration: _cardDecoration,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none_rounded, size: 56, color: AppColors.primary),
            SizedBox(height: 20),
            Text(
              'Wake word detected',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onBackground,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Listening for your claim...',
              style: TextStyle(fontSize: 14, color: AppColors.onSurface),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListeningCard() {
    return Container(
      key: const ValueKey('listening'),
      margin: const EdgeInsets.all(20),
      decoration: _cardDecoration,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulsingMicIcon(),
            SizedBox(height: 20),
            Text(
              'Listening',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onBackground,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Speak your claim now',
              style: TextStyle(fontSize: 14, color: AppColors.onSurface),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingCard() {
    return Container(
      key: const ValueKey('processing'),
      margin: const EdgeInsets.all(20),
      decoration: _cardDecoration,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: AppColors.primary,
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Processing',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onBackground,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Verifying your claim...',
              style: TextStyle(fontSize: 14, color: AppColors.onSurface),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeakingCard(ClaimModel? claim) {
    if (claim == null) {
      return Container(
        key: const ValueKey('speaking'),
        margin: const EdgeInsets.all(20),
        decoration: _cardDecoration,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.volume_up_rounded, size: 56, color: AppColors.primary),
              SizedBox(height: 20),
              Text(
                'Speaking',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onBackground,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Playing response...',
                style: TextStyle(fontSize: 14, color: AppColors.onSurface),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      key: const ValueKey('verdict'),
      margin: const EdgeInsets.all(20),
      decoration: _cardDecoration,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Result',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),
            VerdictBadge(
              verdict: claim.llmVerdict,
              size: VerdictBadgeSize.large,
            ),
            const SizedBox(height: 16),
            Text(
              'Risk: ${claim.riskLevel}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.riskColor(claim.riskLevel),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              claim.correctiveResponse ?? 'No corrective response available.',
              style: const TextStyle(
                fontSize: 14,
                height: 1.5,
                color: AppColors.onBackground,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Verify another'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ResultScreen(claim: claim),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Full report'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      key: const ValueKey('error'),
      margin: const EdgeInsets.all(20),
      decoration: _cardDecoration,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: AppColors.verdictFalse,
            ),
            const SizedBox(height: 20),
            const Text(
              'Something went wrong',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onBackground,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Please try again.',
              style: TextStyle(fontSize: 14, color: AppColors.onSurface),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingMicIcon extends StatefulWidget {
  const _PulsingMicIcon();

  @override
  State<_PulsingMicIcon> createState() => _PulsingMicIconState();
}

class _PulsingMicIconState extends State<_PulsingMicIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _opacityAnimation.value,
          child: Transform.scale(
            scale: _scaleAnimation.value,
            child: const Icon(
              Icons.mic_rounded,
              size: 56,
              color: AppColors.primary,
            ),
          ),
        );
      },
    );
  }
}
