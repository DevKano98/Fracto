// ========== FILE: lib/screens/settings_screen.dart ==========

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/background_service.dart';
import '../services/overlay_service.dart';
import '../services/voice_assistant_service.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _serviceRunning = false;
  bool _bubbleEnabled = false;
  bool _overlayPermission = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final running = await FractaBackgroundService.isRunning;
    final bubble = await OverlayService.isBubbleVisible;
    final perm = await OverlayService.hasPermission;
    if (mounted) {
      setState(() {
        _serviceRunning = running;
        _bubbleEnabled = bubble;
        _overlayPermission = perm;
      });
    }
  }

  Future<void> _toggleService(bool enable) async {
    if (enable) {
      await FractaBackgroundService.start();
    } else {
      await FractaBackgroundService.stop();
      if (_bubbleEnabled) await OverlayService.hideBubble();
    }
    await _loadStatus();
  }

  Future<void> _toggleBubble(bool enable) async {
    if (enable) {
      if (!_overlayPermission) {
        final granted = await OverlayService.requestPermission();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Draw-over-apps permission is required for the floating bubble.\nGo to Settings → Apps → Fracta → Appear on top'),
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
      }
      if (!_serviceRunning) await FractaBackgroundService.start();
      await OverlayService.showBubble();
    } else {
      await OverlayService.hideBubble();
    }
    await _loadStatus();
  }

  Future<void> _requestOverlayPermission() async {
    await OverlayService.requestPermission();
    await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Voice Assistant ──────────────────────────────────────
          _SectionTitle('Voice Assistant'),
          _SettingsCard(
            children: [
              Consumer<VoiceAssistantService>(
                builder: (context, assistant, _) => _EditableNameTile(
                  icon: Icons.mic_outlined,
                  iconColor: AppColors.primary,
                  title: 'Assistant Name',
                  currentName: assistant.assistantName,
                  onSave: (newName) => assistant.setAssistantName(newName),
                ),
              ),
              const _Divider(),
              Consumer<VoiceAssistantService>(
                builder: (context, assistant, _) => _InfoTile(
                  icon: Icons.hearing_outlined,
                  title: 'Wake Phrase',
                  subtitle: '"${assistant.wakePhrase}"',
                ),
              ),
              const _Divider(),
              Consumer<VoiceAssistantService>(
                builder: (context, assistant, _) => _ActionTile(
                  icon: Icons.play_arrow_outlined,
                  iconColor: AppColors.primary,
                  title: 'Test assistant now',
                  subtitle: 'Manually trigger the voice assistant',
                  onTap: () => assistant.manualWake(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Background Service ───────────────────────────────────
          _SectionTitle('Background Service'),
          _SettingsCard(
            children: [
              _ToggleTile(
                icon: Icons.shield_rounded,
                iconColor: AppColors.primary,
                title: 'Fracta background service',
                subtitle: _serviceRunning
                    ? 'Running — ready to verify in seconds'
                    : 'Off — start to enable quick verification',
                value: _serviceRunning,
                onChanged: _toggleService,
              ),
              const _Divider(),
              _InfoTile(
                icon: Icons.notifications_outlined,
                title: 'Persistent notification',
                subtitle:
                    'Shows "Fracta is active" — required to keep the service alive on Android',
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Floating Bubble ──────────────────────────────────────
          _SectionTitle('Floating Bubble'),
          _SettingsCard(
            children: [
              if (!_overlayPermission)
                _ActionTile(
                  icon: Icons.warning_amber_rounded,
                  iconColor: AppColors.verdictMisleading,
                  title: 'Draw-over-apps permission needed',
                  subtitle: 'Tap to grant "Appear on top" permission',
                  onTap: _requestOverlayPermission,
                ),
              if (!_overlayPermission) const _Divider(),
              _ToggleTile(
                icon: Icons.bubble_chart_outlined,
                iconColor: AppColors.primary,
                title: 'Floating bubble',
                subtitle: _bubbleEnabled
                    ? 'Visible — drag to reposition'
                    : 'Hidden — enable to fact-check without opening Fracta',
                value: _bubbleEnabled,
                onChanged: _overlayPermission ? _toggleBubble : null,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Share Integration ────────────────────────────────────
          _SectionTitle('Share Integration'),
          _SettingsCard(
            children: [
              const _InfoTile(
                icon: Icons.share_outlined,
                title: 'Share from any app',
                subtitle:
                    'In WhatsApp, Chrome, Twitter etc. tap Share → Fracta to instantly verify',
              ),
              const _Divider(),
              const _InfoTile(
                icon: Icons.content_paste_outlined,
                title: 'Auto-detect pasted URLs',
                subtitle:
                    'When you copy a URL, Fracta can offer to check it automatically',
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── How It Works ─────────────────────────────────────────
          _SectionTitle('How Fracta Works'),
          _SettingsCard(
            children: [
              const _InfoTile(
                icon: Icons.looks_one_outlined,
                title: '1. You encounter a claim',
                subtitle:
                    'A WhatsApp forward, news headline, social media post, or something you hear',
              ),
              const _Divider(),
              const _InfoTile(
                icon: Icons.looks_two_outlined,
                title: '2. Invoke Fracta',
                subtitle:
                    'Tap the floating bubble, share from the app, or open Fracta and type/speak',
              ),
              const _Divider(),
              const _InfoTile(
                icon: Icons.looks_3_outlined,
                title: '3. AI verifies in seconds',
                subtitle:
                    'Searches 9 trusted sources (PIB, WHO, Reuters…) + Gemini AI analysis',
              ),
              const _Divider(),
              const _InfoTile(
                icon: Icons.looks_4_outlined,
                title: '4. Get verdict + correction',
                subtitle:
                    'TRUE / FALSE / MISLEADING with evidence, risk score, and a shareable correction',
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Account ──────────────────────────────────────────────
          _SectionTitle('Account'),
          Consumer<AuthProvider>(
            builder: (context, auth, _) {
              if (!auth.isLoggedIn) {
                return _SettingsCard(
                  children: [
                    const _InfoTile(
                      icon: Icons.person_outline,
                      title: 'Not logged in',
                      subtitle:
                          'Login to save history, use voice, and report claims',
                    ),
                  ],
                );
              }
              return _SettingsCard(
                children: [
                  _InfoTile(
                    icon: Icons.person_outline,
                    title: auth.user!.name,
                    subtitle: auth.user!.email,
                  ),
                  if (auth.user!.isOperator) ...[
                    const _Divider(),
                    const _InfoTile(
                      icon: Icons.verified_outlined,
                      iconColor: AppColors.verdictMisleading,
                      title: 'Operator account',
                      subtitle:
                          'You have elevated permissions to review and override verdicts',
                    ),
                  ],
                  const _Divider(),
                  _ActionTile(
                    icon: Icons.logout,
                    iconColor: AppColors.verdictFalse,
                    title: 'Logout',
                    subtitle: 'Clears tokens from secure storage',
                    onTap: () async {
                      await auth.logout();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 32),

          // App version
          const Center(
            child: Text(
              'Fracta v1.0.0 • Real-time misinformation defense',
              style: TextStyle(color: AppColors.onSurface, fontSize: 11),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: children),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final void Function(bool)? onChanged;

  const _ToggleTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.onSurface, fontSize: 11)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;

  const _InfoTile({
    required this.icon,
    this.iconColor = AppColors.onSurface,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.onSurface,
                        fontSize: 11,
                        height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: iconColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.onSurface, fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: AppColors.onSurface, size: 18),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
        height: 1, indent: 62, color: AppColors.surfaceVariant);
  }
}

class _EditableNameTile extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String currentName;
  final void Function(String) onSave;

  const _EditableNameTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.currentName,
    required this.onSave,
  });

  @override
  State<_EditableNameTile> createState() => _EditableNameTileState();
}

class _EditableNameTileState extends State<_EditableNameTile> {
  bool _isEditing = false;
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void didUpdateWidget(_EditableNameTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentName != widget.currentName) {
      _controller.text = widget.currentName;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleEdit() {
    setState(() {
      _isEditing = !_isEditing;
      if (!_isEditing) {
        widget.onSave(_controller.text.trim());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: widget.iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(widget.icon, size: 18, color: widget.iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                if (_isEditing)
                  TextField(
                    controller: _controller,
                    style: const TextStyle(
                        color: AppColors.onSurface, fontSize: 11),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _toggleEdit(),
                  )
                else
                  Text('"${widget.currentName}"',
                      style: const TextStyle(
                          color: AppColors.onSurface, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_isEditing ? Icons.check : Icons.edit,
                color: widget.iconColor, size: 18),
            onPressed: _toggleEdit,
          ),
        ],
      ),
    );
  }
}