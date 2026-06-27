import 'dart:ui';
import 'package:flutter/material.dart';
import 'setup_view.dart';
import 'profile_view.dart';
import 'settings_view.dart';

class MainContainerView extends StatefulWidget {
  const MainContainerView({super.key});

  @override
  State<MainContainerView> createState() => _MainContainerViewState();
}

class _MainContainerViewState extends State<MainContainerView> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    SetupView(),
    ProfileView(),
    SettingsView(),
  ];

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.primaryColor;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0B132B), // Deep dark blue-slate
              Color(0xFF050811), // Rich dark black
            ],
          ),
        ),
        child: Stack(
          children: [
            // 1. Pages (State-preserving IndexedStack)
            Positioned.fill(
              child: IndexedStack(
                index: _currentIndex,
                children: _pages,
              ),
            ),

            // 2. Floating Pill Navigation Bar
            Positioned(
              left: 20,
              right: 20,
              bottom: 24,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(32),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        height: 64,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(
                            color: const Color(0xFF1E293B).withValues(alpha: 0.9),
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildNavItem(
                              index: 0,
                              icon: Icons.tune_rounded,
                              label: "Setup",
                              accentColor: accentColor,
                            ),
                            _buildNavItem(
                              index: 1,
                              icon: Icons.person_rounded,
                              label: "Profile",
                              accentColor: accentColor,
                            ),
                            _buildNavItem(
                              index: 2,
                              icon: Icons.settings_rounded,
                              label: "Settings",
                              accentColor: accentColor,
                            ),
                          ],
                        ),
                      ),
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

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required String label,
    required Color accentColor,
  }) {
    final isSelected = _currentIndex == index;
    
    return GestureDetector(
      onTap: () => _onTabTapped(index),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: isSelected ? 1.1 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                icon,
                color: isSelected ? accentColor : const Color(0xFF64748B),
                size: 24,
              ),
            ),
            const SizedBox(height: 4),
            // Tiny active indicator dot or label
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: isSelected ? 4 : 0,
              height: isSelected ? 4 : 0,
              decoration: BoxDecoration(
                color: accentColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
