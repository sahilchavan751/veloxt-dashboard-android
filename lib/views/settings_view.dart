import 'package:flutter/material.dart';
import '../theme/theme_manager.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
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
            // Header
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Text(
                "Settings",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
            ),
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
