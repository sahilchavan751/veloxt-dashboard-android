import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../theme/theme_manager.dart';
import '../services/update_service.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String _currentVersion = "Loading...";
  bool _isCheckingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _currentVersion = info.version;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _currentVersion = "2.2.2";
      });
    }
  }

  Future<void> _handleCheckForUpdates() async {
    setState(() {
      _isCheckingUpdate = true;
    });
    await UpdateService.checkForUpdate(context, isManualCheck: true);
    if (!mounted) return;
    setState(() {
      _isCheckingUpdate = false;
    });
  }

  void _selectPreset(Color color) {
    ThemeManager.setAccentColor(color);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            Expanded(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Theme Customization Card
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFF1E293B),
                              width: 1.2,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "THEME CUSTOMIZATION",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF64748B),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(height: 18),
                              const Text(
                                "Select Accent Theme",
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                "Changes the global highlight color across the entire node interface instantly.",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 20),
                              
                              // Presets Row
                              AnimatedBuilder(
                                animation: ThemeManager.accentColorNotifier,
                                builder: (context, child) {
                                  final currentAccent = ThemeManager.accentColor;
                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: ThemeManager.presets.map((preset) {
                                      final isSelected = currentAccent == preset.color;
                                      return GestureDetector(
                                        onTap: () => _selectPreset(preset.color),
                                        child: Column(
                                          children: [
                                            AnimatedContainer(
                                              duration: const Duration(milliseconds: 200),
                                              width: 46,
                                              height: 46,
                                              decoration: BoxDecoration(
                                                color: preset.color.withValues(alpha: 0.15),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: isSelected 
                                                      ? preset.color 
                                                      : const Color(0xFF1E293B),
                                                  width: isSelected ? 2.5 : 1.5,
                                                ),
                                              ),
                                              alignment: Alignment.center,
                                              child: isSelected 
                                                  ? Icon(
                                                      Icons.check_rounded, 
                                                      color: preset.color,
                                                      size: 20,
                                                    )
                                                  : Container(
                                                      width: 14,
                                                      height: 14,
                                                      decoration: BoxDecoration(
                                                        color: preset.color,
                                                        shape: BoxShape.circle,
                                                      ),
                                                    ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              preset.name,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: isSelected 
                                                    ? FontWeight.w700 
                                                    : FontWeight.w500,
                                                color: isSelected 
                                                    ? Colors.white 
                                                    : const Color(0xFF64748B),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Software Updates Card
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFF1E293B),
                              width: 1.2,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "SOFTWARE UPDATES",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF64748B),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "App Version",
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: Color(0xFF94A3B8),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    "v$_currentVersion",
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              GestureDetector(
                                onTap: _isCheckingUpdate ? null : _handleCheckForUpdates,
                                child: Container(
                                  height: 44,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0xFF10B981).withValues(alpha: 0.4),
                                      width: 1.0,
                                    ),
                                  ),
                                  child: _isCheckingUpdate
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                                          ),
                                        )
                                      : const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.sync_rounded, size: 18, color: Color(0xFF10B981)),
                                            SizedBox(width: 8),
                                            Text(
                                              "Check for Updates",
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF10B981),
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // System Info Card
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFF1E293B),
                              width: 1.2,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                "SYSTEM INFORMATION",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF64748B),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              SizedBox(height: 16),
                              _SystemInfoRow(label: "Node Engine", value: "Veloxt Core v2.4"),
                              Padding(
                                padding: EdgeInsets.symmetric(vertical: 10.0),
                                child: Divider(color: Color(0xFF1E293B), height: 1),
                              ),
                              _SystemInfoRow(label: "Protocol Target", value: "RTMP Streaming"),
                              Padding(
                                padding: EdgeInsets.symmetric(vertical: 10.0),
                                child: Divider(color: Color(0xFF1E293B), height: 1),
                              ),
                              _SystemInfoRow(label: "Secure Encryption", value: "AES-256 Enabled"),
                            ],
                          ),
                        ),
                        
                        // Add bottom padding to account for the floating navigation pill
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SystemInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _SystemInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13.5,
            color: Color(0xFF94A3B8),
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13.5,
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
