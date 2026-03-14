// ========== FILE: lib/screens/home_screen.dart ==========

import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants.dart';
import '../models/claim_model.dart';
import '../providers/auth_provider.dart';
import '../providers/claim_provider.dart';
import '../services/background_service.dart';
import '../services/share_handler_service.dart';
import '../services/floating_bubble_service.dart';
import '../services/overlay_service.dart';
import '../services/voice_assistant_service.dart';
import 'assistant_overlay_screen.dart';
import '../theme.dart';
import '../widgets/input_type_selector.dart';
import '../widgets/verdict_badge.dart';
import 'history_screen.dart';
import 'loading_screen.dart';
import 'login_screen.dart';
import 'quick_capture_screen.dart';
import 'result_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  InputType _selectedType = InputType.text;
  final _textController = TextEditingController();
  final _urlController = TextEditingController();
  String _platform = 'unknown';
  int _shares = 0;
  XFile? _selectedImage;
  bool _isRecording = false;
  bool _hasRecording = false;
  String? _recordingPath;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;

  bool _isNavigating = false;
  final AudioRecorder _recorder = AudioRecorder();
  bool _historyLoaded = false;
  Uint8List? _previewBytes;

  // ── Background service + share wiring ─────────────────────────────
  final ShareHandlerService _shareHandler = ShareHandlerService();
  StreamSubscription? _verdictSub;
  StreamSubscription? _overlaySub;
  StreamSubscription? _assistantSub;
  bool _serviceStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadHistoryIfLoggedIn();
      await _startBackgroundServiceIfNeeded();
      _wireShareHandler();
      _wireOverlayMessages();
      _wireVerdictStream();
      _wireVoiceAssistant();
    });
  }

  // ── Start background service after permissions ─────────────────────
  Future<void> _startBackgroundServiceIfNeeded() async {
    if (_serviceStarted) return;
    _serviceStarted = true;

    // Request notification permission (Android 13+)
    final notifStatus = await Permission.notification.request();
    // Request microphone
    final micStatus = await Permission.microphone.request();

    if (notifStatus.isDenied || micStatus.isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Permissions required for full functionality'),
            action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
          ),
        );
      }
    }

    final running = await FractaBackgroundService.isRunning;
    if (!running) await FractaBackgroundService.start();

    // Restore bubble if it was on before (FloatingBubbleService ensures permission + service)
    final wasOn = await OverlayService.wasBubbleEnabled;
    if (wasOn) {
      final hasPerm = await FloatingBubbleService.hasOverlayPermission;
      if (hasPerm) {
        await FloatingBubbleService.enableBubble(
          startBackgroundService: FractaBackgroundService.start,
        );
      } else if (mounted) {
        final grant = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Floating Bubble'),
            content: const Text(
              'Fracta uses a floating bubble to let you fact-check from any app. This requires the "Appear on top" permission.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enable')),
            ],
          ),
        );
        if (grant == true) await FloatingBubbleService.requestOverlayPermission();
      }
    }
  }

  // ── Wire share-from-other-apps ─────────────────────────────────────
  void _wireShareHandler() {
    _shareHandler.initialize(
      onTextReceived: (text, sourceApp) {
        // Show quick-capture sheet pre-filled with the shared text
        if (mounted) {
          QuickCaptureScreen.show(context, sharedText: text);
        }
      },
      onUrlReceived: (url, sourceApp) {
        if (mounted) {
          QuickCaptureScreen.show(context, sharedUrl: url);
        }
      },
    );
  }

  // ── Wire overlay bubble tap → open quick-capture ───────────────────
  void _wireOverlayMessages() {
    _overlaySub = OverlayService.overlayMessages.listen((data) {
      if (data['action'] == 'open_capture') {
        if (mounted) QuickCaptureScreen.show(context);
      }
    });
  }

  // ── Wire background service verdict → navigate to result ──────────
  void _wireVerdictStream() {
    _verdictSub = FractaBackgroundService.verdictStream.listen((data) {
      if (data != null && mounted && !_isNavigating) {
        final claim = ClaimModel.fromJson(data);
        setState(() => _isNavigating = true);
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ResultScreen(claim: claim)),
        ).then((_) {
          if (mounted) setState(() => _isNavigating = false);
        });
      }
    });
  }

  // ── Wire voice assistant events → show overlay ───────────────────
  void _wireVoiceAssistant() {
    final assistant = context.read<VoiceAssistantService>();
    assistant.initialize().then((_) {
      assistant.startListening();
      _assistantSub = assistant.events.listen((state) {
        if (!mounted) return;
        // Point 2: Only trigger show() on woken state to prevent stacking
        if (state == VoiceAssistantState.woken) {
          AssistantOverlayScreen.show(context);
        }
      });
    });
  }

  Future<void> _loadHistoryIfLoggedIn() async {
    if (_historyLoaded) return;
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isLoggedIn) return;
    final token = await authProvider.getAccessToken();
    if (token == null || token.isEmpty) return;
    _historyLoaded = true;
    await context.read<ClaimProvider>().loadHistory(token, refresh: true);
  }

  @override
  void dispose() {
    _textController.dispose();
    _urlController.dispose();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _shareHandler.dispose();
    _verdictSub?.cancel();
    _overlaySub?.cancel();
    _assistantSub?.cancel();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.of(context).pop();
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1920,
    );
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() {
        _selectedImage = image;
        _previewBytes = bytes;
      });
    }
  }

  void _showImagePickerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined,
                  color: AppColors.primary),
              title: const Text('Take Photo',
                  style: TextStyle(color: AppColors.onBackground)),
              onTap: () => _pickImage(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.primary),
              title: const Text('Choose from Gallery',
                  style: TextStyle(color: AppColors.onBackground)),
              onTap: () => _pickImage(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      _recordingTimer?.cancel();
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _hasRecording = path != null;
        _recordingPath = path;
      });
    } else {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission required')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      // Point 19: Use fixed filename to avoid infinite temp file leak
      final path = '${dir.path}/fracta_manual_recording.m4a';
      
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          numChannels: 1,
          sampleRate: 16000,
          bitRate: 128000,
        ),
        path: path,
      );
      setState(() {
        _isRecording = true;
        _hasRecording = false;
        _recordingDuration = Duration.zero;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isRecording) {
          setState(() => _recordingDuration += const Duration(seconds: 1));
        }
      });
    }
  }

  String _formatDuration(Duration d) {
    final min = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  Future<void> _verifyClaim() async {
    // Validate input
    switch (_selectedType) {
      case InputType.text:
        if (_textController.text.trim().isEmpty) {
          _showError('Please enter a claim to verify');
          return;
        }
        break;
      case InputType.image:
        if (_selectedImage == null) {
          _showError('Please select an image');
          return;
        }
        break;
      case InputType.url:
        if (_urlController.text.trim().isEmpty) {
          _showError('Please enter a URL');
          return;
        }
        final urlStr = _urlController.text.trim();
        if (!urlStr.startsWith('http://') && !urlStr.startsWith('https://')) {
          _showError('Please enter a valid URL starting with http:// or https://');
          return;
        }
        break;
      case InputType.voice:
        if (!_hasRecording || _recordingPath == null) {
          _showError('Please record a voice clip first');
          return;
        }
        break;
    }

    final authProvider = context.read<AuthProvider>();
    String? accessToken = await authProvider.refreshIfNeeded() ?? await authProvider.getAccessToken();

    // Read bytes if needed
    List<int>? imageBytes;
    String? imageFilename;
    if (_selectedType == InputType.image && _selectedImage != null) {
      imageBytes = await _selectedImage!.readAsBytes();
      imageFilename = _selectedImage!.name;
    }

    List<int>? audioBytes;
    String? audioFilename;
    if (_selectedType == InputType.voice && _recordingPath != null) {
      audioBytes = await File(_recordingPath!).readAsBytes();
      audioFilename = 'recording.m4a';
    }

    if (!mounted) return;

    setState(() => _isNavigating = true);
    final route = MaterialPageRoute(
      builder: (_) => LoadingScreen(
        inputType: _selectedType,
        text: _textController.text.trim(),
        imageBytes: imageBytes,
        imageFilename: imageFilename,
        url: _urlController.text.trim(),
        audioBytes: audioBytes,
        audioFilename: audioFilename,
        platform: _platform,
        shares: _shares,
        accessToken: accessToken,
      ),
    );
    Navigator.of(context).push(route).then((_) {
      if (mounted) setState(() => _isNavigating = false);
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shield_rounded,
                    color: AppColors.primary, size: 22),
                const SizedBox(width: 6),
                const Text(
                  'Fracta',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
              ],
            ),
            actions: [
              // Settings (always visible)
              IconButton(
                icon: const Icon(Icons.settings_outlined,
                    color: AppColors.onSurface),
                onPressed: () {
                  if (!mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
              if (auth.isLoggedIn) ...[
                IconButton(
                  icon: const Icon(Icons.history, color: AppColors.onSurface),
                  onPressed: () {
                    if (!mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const HistoryScreen()),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () {
                      if (!mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const HistoryScreen()),
                      );
                    },
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: AppColors.primary,
                          child: Text(
                            auth.user!.initials,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (auth.user!.isOperator)
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: AppColors.verdictMisleading,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ] else
                TextButton(
                  onPressed: () {
                    if (!mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                  },
                  child: const Text('Login',
                      style: TextStyle(color: AppColors.primary)),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tagline
                const Text(
                  'From claim to correction in under 6 seconds',
                  style: TextStyle(
                      color: AppColors.onSurface, fontSize: 12),
                ),
                const SizedBox(height: 16),

                // Input type selector
                InputTypeSelector(
                  selected: _selectedType,
                  onChanged: (t) {
                    setState(() {
                      _selectedType = t;
                    });
                  },
                ),
                const SizedBox(height: 20),

                // Dynamic input area
                _buildInputArea(),
                const SizedBox(height: 20),

                // Verify button
                ElevatedButton.icon(
                  onPressed: _verifyClaim,
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Verify Claim'),
                ),

                if (!auth.isLoggedIn) ...[
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'Login to save your verification history',
                      style: TextStyle(
                          color: AppColors.onSurface, fontSize: 12),
                    ),
                  ),
                ],

                const SizedBox(height: 28),

                // Recent verifications (only if logged in)
                if (auth.isLoggedIn) _buildRecentSection(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputArea() {
    switch (_selectedType) {
      case InputType.text:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _textController,
              maxLines: 5,
              style: const TextStyle(color: AppColors.onBackground),
              decoration: const InputDecoration(
                hintText:
                    'Paste WhatsApp forward, news claim, or any text...',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            _buildPlatformShareRow(),
          ],
        );

      case InputType.image:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: _showImagePickerSheet,
              child: Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.primary.withOpacity(0.5),
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.surfaceVariant,
                ),
                child: _selectedImage == null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              size: 44, color: AppColors.primary),
                          SizedBox(height: 10),
                          Text(
                            'Tap to upload image or take photo',
                            style: TextStyle(
                                color: AppColors.onSurface, fontSize: 13),
                          ),
                        ],
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_previewBytes != null)
                              Image.memory(_previewBytes!, fit: BoxFit.cover),
                            if (_previewBytes == null)
                              const Center(child: CircularProgressIndicator()),
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: ElevatedButton.icon(
                                onPressed: _showImagePickerSheet,
                                icon: const Icon(Icons.swap_horiz, size: 14),
                                label: const Text('Change'),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(0, 34),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  textStyle: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _buildPlatformShareRow(),
          ],
        );

      case InputType.url:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: AppColors.onBackground),
              decoration: const InputDecoration(
                hintText: 'Paste article or social media link',
                prefixIcon:
                    Icon(Icons.link, color: AppColors.onSurface),
              ),
            ),
            const SizedBox(height: 12),
            _buildPlatformShareRow(),
          ],
        );

      case InputType.voice:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _toggleRecording,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isRecording
                            ? AppColors.verdictFalse
                            : _hasRecording
                                ? AppColors.verdictTrue
                                : AppColors.surfaceVariant,
                        boxShadow: _isRecording
                            ? [
                                BoxShadow(
                                  color: AppColors.verdictFalse
                                      .withOpacity(0.5),
                                  blurRadius: 20,
                                  spreadRadius: 4,
                                )
                              ]
                            : [],
                      ),
                      child: Icon(
                        _isRecording
                            ? Icons.stop
                            : _hasRecording
                                ? Icons.check
                                : Icons.mic,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isRecording
                        ? 'Recording... tap to stop  ${_formatDuration(_recordingDuration)}'
                        : _hasRecording
                            ? 'Ready — tap Verify'
                            : 'Tap to start recording',
                    style: const TextStyle(
                        color: AppColors.onSurface, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildPlatformShareRow(),
          ],
        );
    }
  }

  Widget _buildPlatformShareRow() {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _platform,
            dropdownColor: AppColors.surface,
            style: const TextStyle(
                color: AppColors.onBackground, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Platform',
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            items: AppConstants.platforms
                .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text(AppConstants.platformLabels[p] ?? p),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _platform = v ?? 'unknown'),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 100,
          child: TextFormField(
            initialValue: '0',
            keyboardType: TextInputType.number,
            style: const TextStyle(color: AppColors.onBackground),
            decoration: const InputDecoration(labelText: 'Shares'),
            onChanged: (v) => _shares = int.tryParse(v) ?? 0,
          ),
        ),
      ],
    );
  }

  Widget _buildRecentSection(BuildContext context) {
    return Consumer<ClaimProvider>(
      builder: (context, claimProvider, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Recent',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.onBackground,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const HistoryScreen()),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('See all →',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (claimProvider.isLoadingHistory &&
                claimProvider.history.isEmpty)
              const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.primary, strokeWidth: 2))
            else if (claimProvider.history.isEmpty)
              const Text(
                'No verifications yet',
                style:
                    TextStyle(color: AppColors.onSurface, fontSize: 13),
              )
            else
              SizedBox(
                height: 130,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: claimProvider.history.take(3).length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final claim = claimProvider.history[index];
                    return _ClaimCard(
                      claim: claim,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                ResultScreen(claim: claim)),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ClaimCard extends StatelessWidget {
  final ClaimModel claim;
  final VoidCallback onTap;

  const _ClaimCard({required this.claim, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: claim.verdictColor.withOpacity(0.3), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VerdictBadge(
                verdict: claim.llmVerdict,
                size: VerdictBadgeSize.small),
            const SizedBox(height: 8),
            Text(
              claim.displayClaim,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.onBackground),
            ),
            const Spacer(),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.riskColor(claim.riskLevel)
                        .withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    claim.riskLevel,
                    style: TextStyle(
                      fontSize: 9,
                      color: AppColors.riskColor(claim.riskLevel),
                      fontWeight: FontWeight.w600,
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
    );
  }
}