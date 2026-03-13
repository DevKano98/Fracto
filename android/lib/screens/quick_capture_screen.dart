// ========== FILE: lib/screens/quick_capture_screen.dart ==========
//
// The quick-capture bottom sheet. Slides up when user taps the bubble
// or invokes Fracta from another app. Stays on top of everything.
//
// Modes:
//   - If text was shared from WhatsApp → pre-fills the text field
//   - Empty → user types, pastes, or taps mic
//   - After submit → shows inline verdict card (no navigation needed)

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import '../providers/auth_provider.dart';
import '../providers/claim_provider.dart';
import '../services/background_service.dart';
import '../theme.dart';
import '../widgets/verdict_badge.dart';
import '../widgets/risk_meter.dart';
import 'result_screen.dart';

class QuickCaptureScreen extends StatefulWidget {
  /// Pre-filled text from a share intent. Null if opened from bubble tap.
  final String? sharedText;
  final String? sharedUrl;

  const QuickCaptureScreen({
    super.key,
    this.sharedText,
    this.sharedUrl,
  });

  /// Show as a bottom sheet over the current route.
  static Future<void> show(
    BuildContext context, {
    String? sharedText,
    String? sharedUrl,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      builder: (_) => QuickCaptureScreen(
        sharedText: sharedText,
        sharedUrl: sharedUrl,
      ),
    );
  }

  @override
  State<QuickCaptureScreen> createState() => _QuickCaptureScreenState();
}

class _QuickCaptureScreenState extends State<QuickCaptureScreen>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _recordTimer;

  _CaptureMode _mode = _CaptureMode.text;
  _VerifyState _state = _VerifyState.idle;
  ClaimModel? _result;
  String? _errorMsg;

  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  String? _recordingPath;

  StreamSubscription? _verdictSub;
  StreamSubscription? _errorSub;

  @override
  void initState() {
    super.initState();

    // Pre-fill from share intent
    if (widget.sharedUrl != null) {
      _textController.text = widget.sharedUrl!;
      _mode = _CaptureMode.url;
    } else if (widget.sharedText != null) {
      _textController.text = widget.sharedText!;
      _mode = _CaptureMode.text;
    }

    // Listen for background service verdict
    _verdictSub = FractaBackgroundService.verdictStream.listen((data) {
      if (data != null && mounted) {
        setState(() {
          _result = ClaimModel.fromJson(data);
          _state = _VerifyState.done;
        });
      }
    });

    _errorSub = FractaBackgroundService.errorStream.listen((data) {
      if (data != null && mounted) {
        setState(() {
          _errorMsg = data['message'] as String? ?? 'Verification failed';
          _state = _VerifyState.error;
        });
      }
    });

    // Auto-focus if empty
    if (widget.sharedText == null && widget.sharedUrl == null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _focusNode.requestFocus());
    } else if (_state == _VerifyState.idle) {
      // Auto-submit if content was pre-filled via share
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    _recorder.dispose();
    _recordTimer?.cancel();
    _verdictSub?.cancel();
    _errorSub?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _mode != _CaptureMode.voice) return;

    setState(() {
      _state = _VerifyState.loading;
      _result = null;
      _errorMsg = null;
    });

    final authProvider = context.read<AuthProvider>();
    final token = await authProvider.refreshIfNeeded() ?? await authProvider.getAccessToken();

    // For voice, use ClaimProvider directly (background service has no voice support)
    if (_mode == _CaptureMode.voice) {
      if (_recordingPath == null) return;
      final bytes = await File(_recordingPath!).readAsBytes();
      final claimProvider = context.read<ClaimProvider>();
      final claim = await claimProvider.verifyClaim(
        type: InputType.voice,
        audioBytes: bytes,
        audioFilename: 'recording.m4a',
        platform: 'unknown',
        shares: 0,
        accessToken: token,
      );
      if (!mounted) return;
      if (claim != null) {
        setState(() {
          _result = claim;
          _state = _VerifyState.done;
        });
      } else {
        setState(() {
          _errorMsg = claimProvider.error ?? 'Voice verification failed';
          _state = _VerifyState.error;
        });
      }
      return;
    }

    // For text/URL, dispatch to background service
    if (_mode == _CaptureMode.url || _looksLikeUrl(text)) {
      FractaBackgroundService.sendUrlForVerification(text);
    } else {
      FractaBackgroundService.sendTextForVerification(text);
    }
    // State will update when verdictStream fires
  }

  bool _looksLikeUrl(String s) =>
      s.startsWith('http://') ||
      s.startsWith('https://') ||
      RegExp(r'^[\w-]+\.[\w.]{2,}').hasMatch(s.trim());

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _textController.text = data!.text!;
      _focusNode.unfocus();
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      _recordTimer?.cancel();
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _recordingPath = path;
      });
      if (path != null) _submit();
    } else {
      final ok = await _recorder.hasPermission();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission needed')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/quick_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          numChannels: 1,
          sampleRate: 16000,
        ),
        path: path,
      );
      setState(() {
        _isRecording = true;
        _recordDuration = Duration.zero;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isRecording) {
          setState(() => _recordDuration += const Duration(seconds: 1));
        }
      });
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _openFullResult() {
    if (_result == null) return;
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ResultScreen(claim: _result!)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: EdgeInsets.only(bottom: bottomInset + 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF444466),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.shield_rounded,
                      color: Color(0xFF6C63FF), size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Fracta — Quick Check',
                    style: TextStyle(
                      color: Color(0xFFF0F0FF),
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Color(0xFFB0B0CC), size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            const Divider(color: Color(0xFF252540), height: 1),
            const SizedBox(height: 12),

            // ── Body depends on state ──────────────────────────────
            if (_state == _VerifyState.idle || _state == _VerifyState.error)
              _buildInputArea(),

            if (_state == _VerifyState.loading) _buildLoadingArea(),

            if (_state == _VerifyState.done && _result != null)
              _buildResultCard(),

            if (_state == _VerifyState.error) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _errorMsg ?? 'Something went wrong',
                  style: const TextStyle(
                      color: Color(0xFFFF4D6D), fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mode selector
          Row(
            children: [
              _ModeChip(
                label: 'Text',
                icon: Icons.edit_note,
                selected: _mode == _CaptureMode.text,
                onTap: () => setState(() => _mode = _CaptureMode.text),
              ),
              const SizedBox(width: 8),
              _ModeChip(
                label: 'URL',
                icon: Icons.link,
                selected: _mode == _CaptureMode.url,
                onTap: () => setState(() => _mode = _CaptureMode.url),
              ),
              const SizedBox(width: 8),
              _ModeChip(
                label: 'Voice',
                icon: Icons.mic,
                selected: _mode == _CaptureMode.voice,
                onTap: () => setState(() => _mode = _CaptureMode.voice),
              ),
              const Spacer(),
              // Paste button
              TextButton.icon(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste,
                    size: 14, color: Color(0xFF6C63FF)),
                label: const Text('Paste',
                    style: TextStyle(
                        color: Color(0xFF6C63FF), fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (_mode == _CaptureMode.voice)
            _buildVoiceInput()
          else
            _buildTextInput(),

          const SizedBox(height: 12),

          // Submit button
          if (_mode != _CaptureMode.voice)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.shield_outlined, size: 18),
                label: const Text('Verify Now'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTextInput() {
    return TextField(
      controller: _textController,
      focusNode: _focusNode,
      maxLines: 4,
      style: const TextStyle(color: Color(0xFFF0F0FF), fontSize: 14),
      decoration: InputDecoration(
        hintText: _mode == _CaptureMode.url
            ? 'Paste article or social media URL...'
            : 'Paste WhatsApp forward or type claim...',
        hintStyle: const TextStyle(color: Color(0xFF888AAA), fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF252540),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.all(14),
      ),
    );
  }

  Widget _buildVoiceInput() {
    return Center(
      child: Column(
        children: [
          GestureDetector(
            onTap: _toggleRecording,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRecording
                    ? const Color(0xFFFF4D6D)
                    : const Color(0xFF6C63FF),
                boxShadow: _isRecording
                    ? [
                        BoxShadow(
                          color:
                              const Color(0xFFFF4D6D).withOpacity(0.5),
                          blurRadius: 20,
                          spreadRadius: 4,
                        )
                      ]
                    : [],
              ),
              child: Icon(
                _isRecording ? Icons.stop : Icons.mic,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isRecording
                ? 'Recording ${_formatDuration(_recordDuration)} — tap to stop'
                : _recordingPath != null
                    ? 'Ready — tap Verify'
                    : 'Tap and speak your claim',
            style: const TextStyle(
                color: Color(0xFFB0B0CC), fontSize: 13),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildLoadingArea() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              color: Color(0xFF6C63FF),
              strokeWidth: 3,
            ),
          ),
          SizedBox(height: 14),
          Text(
            'Verifying with AI...',
            style: TextStyle(
              color: Color(0xFFF0F0FF),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Searching trusted sources',
            style: TextStyle(color: Color(0xFF6C63FF), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    final r = _result!;
    final verdictColor = r.verdictColor;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        children: [
          // Compact verdict row
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: verdictColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: verdictColor.withOpacity(0.5)),
            ),
            child: Row(
              children: [
                VerdictBadge(
                    verdict: r.llmVerdict, size: VerdictBadgeSize.small),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.displayClaim,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFF0F0FF),
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.riskColor(r.riskLevel)
                                  .withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${r.riskLevel} RISK  ${r.riskScore.toStringAsFixed(1)}/10',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.riskColor(r.riskLevel),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Corrective snippet
          if (r.correctiveResponse?.isNotEmpty == true) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF252540),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                r.correctiveResponse!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xFFB0B0CC),
                    fontSize: 12,
                    height: 1.5),
              ),
            ),
            const SizedBox(height: 10),
          ],

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    if (r.correctiveResponse != null) {
                      Clipboard.setData(
                          ClipboardData(text: r.correctiveResponse!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied!')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Copy'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6C63FF),
                    side: const BorderSide(color: Color(0xFF6C63FF)),
                    minimumSize: const Size(0, 40),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _openFullResult,
                  icon: const Icon(Icons.open_in_full, size: 14),
                  label: const Text('Full Report'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 40),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),

          // Verify another
          TextButton(
            onPressed: () => setState(() {
              _state = _VerifyState.idle;
              _result = null;
              _textController.clear();
            }),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB0B0CC),
              padding: const EdgeInsets.symmetric(vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Check another claim',
                style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

enum _CaptureMode { text, url, voice }

enum _VerifyState { idle, loading, done, error }

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color:
              selected ? const Color(0xFF6C63FF) : const Color(0xFF252540),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF6C63FF)
                : const Color(0xFF444466),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13,
                color: selected
                    ? Colors.white
                    : const Color(0xFFB0B0CC)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white
                    : const Color(0xFFB0B0CC),
              ),
            ),
          ],
        ),
      ),
    );
  }
}