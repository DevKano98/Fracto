// ========== FILE: lib/widgets/source_chip.dart ==========

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';

class SourceChip extends StatelessWidget {
  final String url;
  final double? credibilityScore;

  const SourceChip({
    super.key,
    required this.url,
    this.credibilityScore,
  });

  String get _domain {
    try {
      final uri = Uri.parse(url);
      String host = uri.host;
      if (host.startsWith('www.')) host = host.substring(4);
      // Point 16: Handle Internationalized Domain Names (IDNs) if host is punycode xn--
      if (host.contains('xn--')) {
         // Minimal handling: show raw or attempt decode if library was available
         return host; 
      }
      return host.isNotEmpty ? host : url;
    } catch (_) {
      return url.length > 30 ? '${url.substring(0, 30)}...' : url;
    }
  }

  bool get _isHighCredibility => credibilityScore != null && credibilityScore! >= 0.9;

  Future<void> _openUrl() async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _openUrl,
      child: Container(
        constraints: const BoxConstraints(minWidth: 80, maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _isHighCredibility
                ? AppColors.verdictTrue.withOpacity(0.4)
                : AppColors.onSurface.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.language,
              size: 14,
              color: AppColors.onSurface,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _domain,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.onBackground,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_isHighCredibility) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.verified,
                size: 12,
                color: AppColors.verdictTrue,
              ),
            ],
          ],
        ),
      ),
    );
  }
}