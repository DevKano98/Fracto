// ========== FILE: lib/widgets/reasoning_steps.dart ==========

import 'package:flutter/material.dart';
import '../theme.dart';

class ReasoningSteps extends StatefulWidget {
  final List<String> steps;
  final int initialCount;

  const ReasoningSteps({
    super.key,
    required this.steps,
    this.initialCount = 3,
  });

  @override
  State<ReasoningSteps> createState() => _ReasoningStepsState();
}

class _ReasoningStepsState extends State<ReasoningSteps> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final displayCount =
        _expanded ? widget.steps.length : widget.initialCount.clamp(0, widget.steps.length);
    final displayedSteps = widget.steps.take(displayCount).toList();
    final hasMore = widget.steps.length > widget.initialCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...List.generate(displayedSteps.length, (index) {
          final isLast = index == displayedSteps.length - 1 &&
              (!hasMore || _expanded);
          return _StepItem(
            number: index + 1,
            text: displayedSteps[index],
            isLast: isLast,
          );
        }),
        if (hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _expanded
                    ? 'Show less'
                    : 'Show all ${widget.steps.length} steps',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StepItem extends StatelessWidget {
  final int number;
  final String text;
  final bool isLast;

  const _StepItem({
    required this.number,
    required this.text,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column: circle + line
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: AppColors.primary.withOpacity(0.3),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // Right column: step text
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.onBackground,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}