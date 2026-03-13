// ========== FILE: lib/widgets/input_type_selector.dart ==========

import 'package:flutter/material.dart';
import '../constants.dart';
import '../theme.dart';

class InputTypeSelector extends StatelessWidget {
  final InputType selected;
  final ValueChanged<InputType> onChanged;

  const InputTypeSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  static const _types = [
    InputType.text,
    InputType.image,
    InputType.url,
    InputType.voice,
  ];

  static const _labels = {
    InputType.text: 'Text',
    InputType.image: 'Image',
    InputType.url: 'URL',
    InputType.voice: 'Voice',
  };

  static const _icons = {
    InputType.text: Icons.edit_note,
    InputType.image: Icons.image,
    InputType.url: Icons.link,
    InputType.voice: Icons.mic,
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: _types.map((type) {
        final isSelected = selected == type;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: _TypeChip(
              label: _labels[type]!,
              icon: _icons[type]!,
              isSelected: isSelected,
              onTap: () => onChanged(type),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected
                    ? AppColors.primary
                    : AppColors.surfaceVariant,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isSelected ? Colors.white : AppColors.onSurface,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? Colors.white : AppColors.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}