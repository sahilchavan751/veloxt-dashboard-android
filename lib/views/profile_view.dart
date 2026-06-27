import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login_view.dart';

class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  int _registeredCamerasCount = 0;
  bool _isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    _fetchCameraStats();
  }

  Future<void> _fetchCameraStats() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      setState(() => _isLoadingStats = false);
      return;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('active_cameras')
          .get();

      setState(() {
        _registeredCamerasCount = snapshot.docs.length;
        _isLoadingStats = false;
      });
    } catch (e) {
      debugPrint("Failed to fetch camera stats: $e");
      setState(() => _isLoadingStats = false);
    }
  }

  Future<void> _handleSignOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginView()),
        (route) => false,
      );
    } catch (_) {}
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Operator UID copied to clipboard"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final emailDisplay = user?.email ?? "Operator";
    final uidDisplay = user?.uid ?? "N/A";
    final theme = Theme.of(context);

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
                "Profile",
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
                        // Profile Card
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFF1E293B),
                              width: 1.2,
                            ),
                          ),
                          child: Column(
                            children: [
                              // Huge Avatar
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  color: theme.primaryColor.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: theme.primaryColor.withValues(alpha: 0.3),
                                    width: 2,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  emailDisplay.isNotEmpty ? emailDisplay[0].toUpperCase() : "O",
                                  style: TextStyle(
                                    color: theme.primaryColor,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 28,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Email
                              Text(
                                emailDisplay,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              // Role badge
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  "BROADCAST NODE OPERATOR",
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF94A3B8),
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                              const Divider(color: Color(0xFF1E293B), height: 1),
                              const SizedBox(height: 20),
                              // UID row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "OPERATOR UID",
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF64748B),
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => _copyToClipboard(uidDisplay),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 120,
                                          child: Text(
                                            uidDisplay,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF94A3B8),
                                              fontFamily: 'monospace',
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.end,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        const Icon(
                                          Icons.copy_rounded,
                                          size: 13,
                                          color: Color(0xFF64748B),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Stats Card
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
                                "NODE STATISTICS",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF64748B),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "Registered Stream Nodes",
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  _isLoadingStats
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                                          ),
                                        )
                                      : Text(
                                          "$_registeredCamerasCount",
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            color: theme.primaryColor,
                                          ),
                                        ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),

                        // Styled Sign Out Button
                        _InteractiveButton(
                          onPressed: () => _handleSignOut(context),
                          child: Container(
                            height: 50,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFF334155),
                                width: 1.2,
                              ),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.logout_rounded,
                                  size: 16,
                                  color: Color(0xFFEF4444),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  "Sign Out Operator",
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color: Color(0xFFEF4444),
                                  ),
                                ),
                              ],
                            ),
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

class _InteractiveButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const _InteractiveButton({required this.onPressed, required this.child});

  @override
  State<_InteractiveButton> createState() => _InteractiveButtonState();
}

class _InteractiveButtonState extends State<_InteractiveButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        if (widget.onPressed != null) {
          setState(() => _scale = 0.97);
        }
      },
      onTapUp: (_) {
        if (widget.onPressed != null) {
          setState(() => _scale = 1.0);
          widget.onPressed!();
        }
      },
      onTapCancel: () {
        if (widget.onPressed != null) {
          setState(() => _scale = 1.0);
        }
      },
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeInOut,
        child: widget.child,
      ),
    );
  }
}
