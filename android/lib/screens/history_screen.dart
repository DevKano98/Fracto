// ========== FILE: lib/screens/history_screen.dart ==========

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../constants.dart';
import '../models/claim_model.dart';
import '../providers/auth_provider.dart';
import '../providers/claim_provider.dart';
import '../theme.dart';
import '../widgets/verdict_badge.dart';
import 'login_screen.dart';
import 'result_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ScrollController _scrollController = ScrollController();

  bool _fetching = false;

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_handleScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHistory(refresh: true);
    });
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadHistory({bool refresh = false}) async {
    final auth = context.read<AuthProvider>();

    if (!auth.isLoggedIn) return;

    final token = await auth.getAccessToken();

    if (token == null || token.isEmpty) return;

    if (_fetching) return;

    _fetching = true;

    try {
      await context.read<ClaimProvider>().loadHistory(
            token,
            refresh: refresh,
          );
    } finally {
      if (mounted) {
        setState(() => _fetching = false);
      } else {
        _fetching = false;
      }
    }
  }

  void _handleScroll() {
    final claimProvider = context.read<ClaimProvider>();

    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;

    if (position.pixels >= position.maxScrollExtent - 150) {
      if (!claimProvider.isLoadingHistory &&
          claimProvider.hasMoreHistory &&
          !_fetching) {
        _loadHistory();
      }
    }
  }

  IconData _sourceIcon(String? source) {
    switch (source) {
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
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Logout"),
        content: const Text("Are you sure you want to logout?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Logout"),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await auth.logout();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (_, auth, __) {
        if (!auth.isLoggedIn) {
          return _buildLoginPrompt();
        }

        final user = auth.user;

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("My Verifications"),
                if (user != null)
                  Text(
                    user.name,
                    style: const TextStyle(fontSize: 12),
                  )
              ],
            ),
            actions: [
              if (user?.isOperator ?? false)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.verdictMisleading.withOpacity(.2),
                  ),
                  child: const Text(
                    "OPERATOR",
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.logout_outlined),
                onPressed: () => _logout(auth),
              )
            ],
          ),
          body: SafeArea(
            child: Consumer<ClaimProvider>(
              builder: (_, provider, __) {
                if (provider.isLoadingHistory && provider.history.isEmpty) {
                  return _buildShimmer();
                }

                if (provider.history.isEmpty) {
                  return _buildEmptyState();
                }

                return RefreshIndicator(
                  onRefresh: () => _loadHistory(refresh: true),
                  child: ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: provider.history.length +
                        (provider.isLoadingHistory ? 1 : 0) +
                        (provider.error != null ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, index) {
                      if (index < provider.history.length) {
                        final claim = provider.history[index];

                        return _HistoryCard(
                          claim: claim,
                          sourceIcon: _sourceIcon(claim.sourceType),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ResultScreen(claim: claim),
                              ),
                            );
                          },
                        );
                      }

                      if (provider.isLoadingHistory) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }

                      if (provider.error != null) {
                        return _errorBanner(provider);
                      }

                      return const SizedBox.shrink();
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoginPrompt() {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text("My Verifications")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 60),
            const SizedBox(height: 20),
            const Text(
              "Please login to view your history",
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text("Login"),
              onPressed: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LoginScreen(),
                  ),
                );
              },
            )
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_outlined, size: 64),
          SizedBox(height: 16),
          Text("No verifications yet"),
          SizedBox(height: 8),
          Text("Your fact-checks will appear here"),
        ],
      ),
    );
  }

  Widget _errorBanner(ClaimProvider provider) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.verdictFalse.withOpacity(.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline),
          const SizedBox(width: 8),
          Expanded(child: Text(provider.error!)),
          TextButton(
            onPressed: _loadHistory,
            child: const Text("Retry"),
          )
        ],
      ),
    );
  }

  Widget _buildShimmer() {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) {
        return Shimmer.fromColors(
          baseColor: AppColors.surfaceVariant,
          highlightColor: AppColors.surface.withOpacity(.8),
          child: Container(
            height: 90,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      },
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
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: claim.verdictColor.withOpacity(.25),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VerdictBadge(
              verdict: claim.llmVerdict,
              size: VerdictBadgeSize.small,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    claim.displayClaim,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(height: 1.4),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Icon(sourceIcon, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        claim.platform ?? "unknown",
                        style: const TextStyle(fontSize: 11),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.riskColor(claim.riskLevel)
                              .withOpacity(.12),
                        ),
                        child: Text(
                          claim.riskLevel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppColors.riskColor(claim.riskLevel),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        claim.timeAgo,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }
}
