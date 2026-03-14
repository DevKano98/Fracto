// ========== FILE: lib/screens/result_screen.dart ==========

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import '../providers/auth_provider.dart';
import '../providers/claim_provider.dart';
import '../services/sarvam_service.dart';
import '../theme.dart';
import 'package:audioplayers/audioplayers.dart';
import '../widgets/verdict_badge.dart';
import '../widgets/risk_meter.dart';
import '../widgets/reasoning_steps.dart';
import '../widgets/source_chip.dart';
import 'home_screen.dart';
import 'login_screen.dart';

class ResultScreen extends StatefulWidget {
  final ClaimModel claim;

  const ResultScreen({super.key, required this.claim});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _claimExpanded = false;
  bool _reportExpanded = false;
  String _reportType = 'WRONG_VERDICT';
  final _reportNoteController = TextEditingController();
  final _scrollController = ScrollController();
  final _reasoningSectionKey = GlobalKey();
  bool _isSubmittingReport = false;
  bool _reportSubmitted = false;
  bool _isPlayingAudio = false;
  bool _isLoadingAudio = false;
  final SarvamService _sarvamService = SarvamService();

  @override
  void initState() {
    super.initState();
    _sarvamService.playerStateStream.listen((state) {
      if (mounted &&
          (state == PlayerState.stopped || state == PlayerState.completed)) {
        setState(() => _isPlayingAudio = false);
      }
    });
  }

  @override
  void dispose() {
    _reportNoteController.dispose();
    _scrollController.dispose();
    _sarvamService.dispose();
    super.dispose();
  }

  void _scrollToFullReport() {
    final context = _reasoningSectionKey.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _playAudio() async {
    if (_isPlayingAudio) {
      await _sarvamService.stopAudio();
      setState(() => _isPlayingAudio = false);
      return;
    }
    if (widget.claim.aiAudioB64 == null) return;
    setState(() => _isLoadingAudio = true);
    try {
      await _sarvamService.playAudioFromBase64(widget.claim.aiAudioB64!);
      setState(() {
        _isPlayingAudio = true;
        _isLoadingAudio = false;
      });
    } catch (e) {
      setState(() => _isLoadingAudio = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play audio')),
        );
      }
    }
  }

  Future<void> _submitReport() async {
    if (widget.claim.id.isEmpty) return;
    final authProvider = context.read<AuthProvider>();
    final claimProvider = context.read<ClaimProvider>();
    setState(() => _isSubmittingReport = true);
    try {
      final token = await authProvider.refreshIfNeeded() ?? await authProvider.getAccessToken();
      await claimProvider.reportClaim(
        claimId: widget.claim.id,
        reportType: _reportType,
        note: _reportNoteController.text.trim(),
        accessToken: token,
      );
      setState(() {
        _reportSubmitted = true;
        _reportExpanded = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Report submitted. Thank you for your feedback!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit report: $e')),
        );
      }
    } finally {
      setState(() => _isSubmittingReport = false);
    }
  }

  void _copyToClipboard() {
    if (widget.claim.correctiveResponse == null) return;
    Clipboard.setData(ClipboardData(text: widget.claim.correctiveResponse!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard!')),
    );
  }

  void _shareText() {
    if (widget.claim.correctiveResponse == null) return;
    Clipboard.setData(ClipboardData(text: widget.claim.correctiveResponse!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Text copied — paste anywhere to share!')),
    );
  }

  String _flagLabel(String flag) {
    switch (flag) {
      case 'manipulation_detected':
        return 'Image manipulation detected';
      case 'fake_govt_logo':
        return 'Fake government logo found';
      case 'morphed_person':
        return 'Person appears morphed/edited';
      default:
        return flag.replaceAll('_', ' ').toUpperCase();
    }
  }

  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final claim = widget.claim;
    final verdictColor = claim.verdictColor;

    return WillPopScope(
      onWillPop: () async {
        _goHome();
        return false;
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _goHome,
            tooltip: 'Back to Home',
          ),
          title: const Text('Verification Result'),
        ),
        body: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Claim Verification Result Card (modern minimal) ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: verdictColor.withOpacity(0.06),
                      blurRadius: 20,
                      offset: const Offset(0, 2),
                    ),
                  ],
                  border: Border.all(
                    color: verdictColor.withOpacity(0.35),
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Claim Verification Result',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.onSurface,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: VerdictBadge(
                        verdict: claim.llmVerdict,
                        size: VerdictBadgeSize.large,
                        llmConfidence: claim.llmConfidence,
                      ),
                    ),
                    const SizedBox(height: 20),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final narrow = constraints.maxWidth < 340;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RiskMeter(
                              score: claim.riskScore,
                              level: claim.riskLevel,
                              size: narrow ? 120 : 160,
                            ),
                            if (claim.llmConfidence != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceVariant,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  'Confidence ${(claim.llmConfidence! * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.onBackground,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: () =>
                          setState(() => _claimExpanded = !_claimExpanded),
                      child: Text(
                        claim.displayClaim,
                        maxLines: _claimExpanded ? null : 2,
                        overflow: _claimExpanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.onBackground,
                          height: 1.5,
                        ),
                      ),
                    ),
                    if (claim.displayClaim.length > 80) ...[
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _claimExpanded = !_claimExpanded),
                        child: Text(
                          _claimExpanded ? 'Show less' : 'Show more',
                          style: TextStyle(
                            fontSize: 12,
                            color: verdictColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    if (claim.correctiveResponse != null &&
                        claim.correctiveResponse!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Corrective explanation',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        claim.correctiveResponse!,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.onBackground,
                          height: 1.6,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (claim.sources.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Sources',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: claim.sources
                            .take(6)
                            .map((url) => SourceChip(url: url))
                            .toList(),
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Text(
                      'Actions',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _goHome,
                            icon: const Icon(Icons.add_task, size: 18),
                            label: const Text('Verify another claim'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              side: const BorderSide(color: AppColors.primary),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _scrollToFullReport,
                            icon: const Icon(Icons.article_outlined, size: 18),
                            label: const Text('View full report'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── AI Reasoning Chain ─────────────────────────────
              if (claim.reasoningSteps.isNotEmpty) ...[
                _SectionHeader(
                  key: _reasoningSectionKey,
                  title: 'How AI Verified This',
                  icon: Icons.auto_awesome_outlined,
                  tooltip: 'Step-by-step verification chain',
                ),
                const SizedBox(height: 12),
                ReasoningSteps(steps: claim.reasoningSteps),
                const SizedBox(height: 24),
              ],

              // ── Evidence & Sources ─────────────────────────────
              if (claim.sources.isNotEmpty) ...[
                _SectionHeader(
                  title:
                      'Sources Checked (${claim.ragSourcesCount ?? claim.sources.length})',
                  icon: Icons.fact_check_outlined,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: claim.sources.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => SourceChip(url: claim.sources[i]),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // ── Corrective Response ────────────────────────────
              if (claim.correctiveResponse?.isNotEmpty == true) ...[
                _SectionHeader(
                  title: 'Corrective Response',
                  icon: Icons.campaign_outlined,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Share this to counter the misinformation',
                  style: TextStyle(color: AppColors.onSurface, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: AppColors.surfaceVariant, width: 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        claim.correctiveResponse!,
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 14,
                          height: 1.7,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Voice audio button
                      if (claim.sourceType == 'voice' &&
                          claim.aiAudioB64 != null) ...[
                        ElevatedButton.icon(
                          onPressed: _isLoadingAudio ? null : _playAudio,
                          icon: _isLoadingAudio
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : Icon(_isPlayingAudio
                                  ? Icons.stop
                                  : Icons.volume_up),
                          label: Text(_isLoadingAudio
                              ? 'Loading...'
                              : _isPlayingAudio
                                  ? 'Stop Audio'
                                  : '🔊 Hear in Hindi'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],

                      // Copy & Share
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _copyToClipboard,
                              icon: const Icon(Icons.copy, size: 15),
                              label: const Text('Copy'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.primary,
                                side:
                                    const BorderSide(color: AppColors.primary),
                                minimumSize: const Size(0, 42),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _shareText,
                              icon: const Icon(Icons.share_outlined, size: 15),
                              label: const Text('Share'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.primary,
                                side:
                                    const BorderSide(color: AppColors.primary),
                                minimumSize: const Size(0, 42),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // ── Visual Flags ───────────────────────────────────
              if (claim.visualFlags.isNotEmpty) ...[
                _SectionHeader(
                  title: 'Visual Analysis Flags',
                  icon: Icons.warning_amber_rounded,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.verdictFalse.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.verdictFalse.withOpacity(0.4)),
                  ),
                  child: Column(
                    children: claim.visualFlags
                        .map(
                          (f) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warning_rounded,
                                  color: AppColors.verdictFalse,
                                  size: 16,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _flagLabel(f),
                                    style: const TextStyle(
                                      color: AppColors.onBackground,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // ── Report Section (only if claim was saved with valid id) ──
              if (!_reportSubmitted && widget.claim.id.isNotEmpty)
                Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () {
                            if (!auth.isLoggedIn) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('Please login to report a claim'),
                                ),
                              );
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const LoginScreen()),
                              );
                              return;
                            }
                            setState(() => _reportExpanded = !_reportExpanded);
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.flag_outlined,
                                  size: 14, color: AppColors.onSurface),
                              const SizedBox(width: 6),
                              Text(
                                auth.isLoggedIn
                                    ? 'Report incorrect verdict'
                                    : 'Login to report',
                                style: const TextStyle(
                                  color: AppColors.onSurface,
                                  fontSize: 13,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_reportExpanded && auth.isLoggedIn) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(12),
                              border:
                                  Border.all(color: AppColors.surfaceVariant),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'What is wrong with this result?',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.onBackground,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _ReportRadio(
                                  value: 'WRONG_VERDICT',
                                  groupValue: _reportType,
                                  label: 'Verdict is wrong',
                                  onChanged: (v) =>
                                      setState(() => _reportType = v!),
                                ),
                                _ReportRadio(
                                  value: 'MISSING_CONTEXT',
                                  groupValue: _reportType,
                                  label: 'Missing context',
                                  onChanged: (v) =>
                                      setState(() => _reportType = v!),
                                ),
                                _ReportRadio(
                                  value: 'OTHER',
                                  groupValue: _reportType,
                                  label: 'Other',
                                  onChanged: (v) =>
                                      setState(() => _reportType = v!),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _reportNoteController,
                                  style: const TextStyle(
                                      color: AppColors.onBackground),
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                    hintText: 'Additional notes (optional)',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                ElevatedButton(
                                  onPressed: _isSubmittingReport
                                      ? null
                                      : _submitReport,
                                  style: ElevatedButton.styleFrom(
                                    minimumSize:
                                        const Size(double.infinity, 44),
                                  ),
                                  child: _isSubmittingReport
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text('Submit Report'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              if (_reportSubmitted) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.verdictTrue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.verdictTrue.withOpacity(0.4)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          color: AppColors.verdictTrue, size: 16),
                      SizedBox(width: 8),
                      Text(
                        'Report submitted successfully',
                        style: TextStyle(
                          color: AppColors.verdictTrue,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),

              // ── Bottom Actions ─────────────────────────────────
              ElevatedButton.icon(
                onPressed: _goHome,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Verify Another Claim'),
              ),
              const SizedBox(height: 8),
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  if (!auth.isLoggedIn) return const SizedBox.shrink();
                  return OutlinedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Saved to history automatically!'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.bookmark_outline, size: 16),
                    label: const Text('Save to History'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.onSurface,
                      side: const BorderSide(color: AppColors.surfaceVariant),
                      minimumSize: const Size(double.infinity, 52),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Helper Widgets ─────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? tooltip;

  const _SectionHeader({
    super.key,
    required this.title,
    required this.icon,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.onBackground,
          ),
        ),
        if (tooltip != null) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: tooltip!,
            child: const Icon(
              Icons.info_outline,
              size: 14,
              color: AppColors.onSurface,
            ),
          ),
        ],
      ],
    );
  }
}

class _SmallChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _SmallChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppColors.onSurface),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.onSurface),
          ),
        ],
      ),
    );
  }
}

class _ReportRadio extends StatelessWidget {
  final String value;
  final String groupValue;
  final String label;
  final ValueChanged<String?> onChanged;

  const _ReportRadio({
    required this.value,
    required this.groupValue,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RadioListTile<String>(
      value: value,
      groupValue: groupValue,
      onChanged: onChanged,
      title: Text(
        label,
        style: const TextStyle(color: AppColors.onBackground, fontSize: 13),
      ),
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeColor: AppColors.primary,
      visualDensity: VisualDensity.compact,
    );
  }
}
