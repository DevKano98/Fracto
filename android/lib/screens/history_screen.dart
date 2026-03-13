// ========== FILE: lib/screens/history_screen.dart ==========

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import '../models/claim_model.dart';
import '../providers/auth_provider.dart';
import '../providers/claim_provider.dart';
import '../theme.dart';
import '../widgets/verdict_badge.dart';
import '../constants.dart';
import 'login_screen.dart';
import 'result_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _loadHistory(refresh: true));
  }

  Future<void> _loadHistory({bool refresh = false}) async {
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isLoggedIn) return;
    final token = await authProvider.getAccessToken();
    if (token == null || token.isEmpty) return;
    await context
        .read<ClaimProvider>()
        .loadHistory(token, refresh: refresh);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 150) {
      final claimProvider = context.read<ClaimProvider>();
      if (!claimProvider.isLoadingHistory &&
          claimProvider.hasMoreHistory) {
        _loadHistory();
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  IconData _sourceIcon(String? sourceType) {
    switch (sourceType) {
      case 'image':
        return Icons.image_outlined;
      case 'url':
        return Icons.link;
      case 'voice':
        return Icons.mic_outlined;
      default:
        return Icons.text_snippet_outlined;
    }
  }

  Future<void> _logout(AuthProvider auth) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Logout',
            style: TextStyle(color: AppColors.onBackground)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: AppColors.onSurface)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.onSurface)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout',
                style: TextStyle(color: AppColors.verdictFalse)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await auth.logout();
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (!auth.isLoggedIn) {
          return Scaffold(
            backgroundColor: AppColors.background,
            appBar: AppBar(title: const Text('My Verifications')),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline,
                      size: 56, color: AppColors.onSurface),
                  const SizedBox(height: 16),
                  const Text(
                    'Please login to view your history',
                    style: TextStyle(
                        color: AppColors.onSurface, fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushReplacement(MaterialPageRoute(
                            builder: (_) => const LoginScreen())),
                    icon: const Icon(Icons.login),
                    label: const Text('Login'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size(180, 48)),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('My Verifications'),
                Text(
                  auth.user!.name,
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.normal),
                ),
              ],
            ),
            actions: [
              if (auth.user!.isOperator)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.verdictMisleading.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            AppColors.verdictMisleading.withOpacity(0.5)),
                  ),
                  child: const Text(
                    'OPERATOR',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.verdictMisleading,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.logout_outlined,
                    color: AppColors.onSurface),
                onPressed: () => _logout(auth),
                tooltip: 'Logout',
              ),
            ],
          ),
          body: Consumer<ClaimProvider>(
            builder: (context, claimProvider, _) {
              // Loading shimmer
              if (claimProvider.isLoadingHistory &&
                  claimProvider.history.isEmpty) {
                return _buildShimmerList();
              }

              // Empty state
              if (claimProvider.history.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.history_outlined,
                          size: 64, color: AppColors.onSurface),
                      const SizedBox(height: 16),
                      const Text(
                        'No verifications yet',
                        style: TextStyle(
                          color: AppColors.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your fact-checks will appear here',
                        style: TextStyle(
                            color: AppColors.onSurface, fontSize: 13),
                      ),
                      const SizedBox(height: 28),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.shield_outlined),
                        label: const Text('Verify a Claim'),
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size(180, 48)),
                      ),
                    ],
                  ),
                );
              }

              // Error banner
              return RefreshIndicator(
                color: AppColors.primary,
                backgroundColor: AppColors.surface,
                onRefresh: () => _loadHistory(refresh: true),
                child: ListView.separated(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  itemCount: claimProvider.history.length +
                      (claimProvider.isLoadingHistory ? 1 : 0) +
                      (claimProvider.error != null ? 1 : 0),
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    // Loading indicator at bottom
                    if (index == claimProvider.history.length &&
                        claimProvider.isLoadingHistory) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(
                              color: AppColors.primary, strokeWidth: 2),
                        ),
                      );
                    }
                    // Error banner
                    if (claimProvider.error != null &&
                        index == claimProvider.history.length) {
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.verdictFalse.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline,
                                color: AppColors.verdictFalse, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(claimProvider.error!,
                                  style: const TextStyle(
                                      color: AppColors.verdictFalse,
                                      fontSize: 13)),
                            ),
                            TextButton(
                              onPressed: _loadHistory,
                              style: TextButton.styleFrom(
                                  foregroundColor: AppColors.primary),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }

                    final claim = claimProvider.history[index];
                    return _HistoryCard(
                      claim: claim,
                      sourceIcon: _sourceIcon(claim.sourceType),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ResultScreen(claim: claim),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildShimmerList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: 7,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => Shimmer.fromColors(
        baseColor: AppColors.surfaceVariant,
        highlightColor: AppColors.surface.withOpacity(0.8),
        child: Container(
          height: 90,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final ClaimModel claim;
  final IconData sourceIcon;
  final VoidCallback onTap;

  const _HistoryCard({
    required this.claim,
    required this.sourceIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: claim.verdictColor.withOpacity(0.22), width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Verdict badge
            VerdictBadge(
                verdict: claim.llmVerdict,
                size: VerdictBadgeSize.small),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    claim.displayClaim,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.onBackground,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Icon(sourceIcon,
                          size: 12, color: AppColors.onSurface),
                      const SizedBox(width: 4),
                      Text(
                        claim.platform ?? 'unknown',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.onSurface),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.riskColor(claim.riskLevel)
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          claim.riskLevel,
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.riskColor(claim.riskLevel),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        claim.timeAgo,
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.onSurface),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                color: AppColors.onSurface, size: 18),
          ],
        ),
      ),
    );
  }
}