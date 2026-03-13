// ========== FILE: lib/widgets/risk_meter.dart ==========

import 'dart:math';
import 'package:flutter/material.dart';
import '../theme.dart';

class RiskMeter extends StatelessWidget {
  final double score;
  final String level;
  final double size;

  const RiskMeter({
    super.key,
    required this.score,
    required this.level,
    this.size = 160,
  });

  Color get _levelColor => AppColors.riskColor(level);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RiskMeterPainter(
          score: score.clamp(0.0, 10.0),
          color: _levelColor,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                score.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: size * 0.22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onBackground,
                ),
              ),
              Text(
                '/ 10',
                style: TextStyle(
                  fontSize: size * 0.10,
                  color: AppColors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RiskMeterPainter extends CustomPainter {
  final double score;
  final Color color;

  static const double _startAngle = 200 * pi / 180; // 200 degrees in radians
  static const double _sweepTotal = 220 * pi / 180; // 220 degrees sweep

  const _RiskMeterPainter({required this.score, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 16;
    const strokeWidth = 12.0;

    // Background arc (gray)
    final bgPaint = Paint()
      ..color = AppColors.surfaceVariant
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      _startAngle,
      _sweepTotal,
      false,
      bgPaint,
    );

    // Score arc (colored)
    final scoreFraction = score / 10.0;
    final scoreSweep = _sweepTotal * scoreFraction;

    if (scoreSweep > 0) {
      final scorePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        _startAngle,
        scoreSweep,
        false,
        scorePaint,
      );

      // Glow effect
      final glowPaint = Paint()
        ..color = color.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 6
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        _startAngle,
        scoreSweep,
        false,
        glowPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RiskMeterPainter oldDelegate) =>
      oldDelegate.score != score || oldDelegate.color != color;
}