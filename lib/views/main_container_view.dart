import 'dart:ui';
import 'package:flutter/material.dart';
import 'setup_view.dart';
import 'profile_view.dart';
import 'settings_view.dart';
import '../services/update_service.dart';

class MainContainerView extends StatefulWidget {
  const MainContainerView({super.key});

  @override
  State<MainContainerView> createState() => _MainContainerViewState();
}

class _MainContainerViewState extends State<MainContainerView> {
  int _currentIndex = 0;
  late final PageController _pageController;

  final List<Widget> _pages = const [
    SetupView(),
    ProfileView(),
    SettingsView(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);
    // Check for app updates in the background 2 seconds after launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          UpdateService.checkForUpdate(context);
        }
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
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
            // 1. Pages (Swipeable PageView)
            Positioned.fill(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                },
                children: _pages,
              ),
            ),

            // 2. Left-Aligned Compact Floating Pill Navigation Bar
            Positioned(
              left: 20,
              bottom: 20,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.9),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 4.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: isSelected ? 1.05 : 0.95,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                icon,
                color: isSelected ? accentColor : const Color(0xFF64748B),
                size: 20,
              ),
            ),
            const SizedBox(height: 3),
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
