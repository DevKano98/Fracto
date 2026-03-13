// ========== FILE: lib/widgets/verdict_badge.dart ==========

import 'package:flutter/material.dart';
import '../constants.dart';
import '../theme.dart';

class VerdictBadge extends StatelessWidget {
  final String verdict;
  final VerdictBadgeSize size;
  final bool showLabel;
  final double? llmConfidence;

  const VerdictBadge({
    super.key,
    required this.verdict,
    this.size = VerdictBadgeSize.large,
    this.showLabel = true,
    this.llmConfidence,
  });

  Color get _color => AppColors.verdictColor(verdict);

  IconData get _icon {
    switch (verdict.toUpperCase()) {
      case 'TRUE':
        return Icons.check;
      case 'FALSE':
        return Icons.close;
      case 'MISLEADING':
        return Icons.warning_amber_rounded;
      default:
        return Icons.help_outline;
    }
  }

  String get _label {
    switch (verdict.toUpperCase()) {
      case 'TRUE':
        return 'TRUE';
      case 'FALSE':
        return 'FALSE';
      case 'MISLEADING':
        return 'MISLEADING';
      default:
        return 'UNVERIFIED';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (size == VerdictBadgeSize.large) {
      return _buildLarge();
    }
    return _buildSmall();
  }

  Widget _buildLarge() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: _color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _color.withOpacity(0.4),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Icon(
            _icon,
            color: Colors.white,
            size: 40,
          ),
        ),
        if (showLabel) ...[
          const SizedBox(height: 10),
          Text(
            _label,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _color,
              letterSpacing: 1.5,
            ),
          ),
          if (llmConfidence != null) ...[
            const SizedBox(height: 4),
            Text(
              '${(llmConfidence! * 100).toStringAsFixed(0)}% confident',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.onSurface,
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildSmall() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      decoration: BoxDecoration(
        color: _color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _color.withOpacity(0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, color: _color, size: 12),
          const SizedBox(width: 4),
          Text(
            _label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _color,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}