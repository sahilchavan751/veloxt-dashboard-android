import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'main_container_view.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final _formKey = GlobalKey<FormState>();
  
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isSignUp = false;
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  String _mapFirebaseError(String code) {
    switch (code) {
      case 'invalid-email':
        return "Invalid email address format.";
      case 'user-disabled':
        return "This operator account has been disabled.";
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return "Invalid email or authentication key.";
      case 'email-already-in-use':
        return "This email is already registered.";
      case 'weak-password':
        return "Password must be at least 6 characters.";
      default:
        return "An unexpected verification error occurred.";
    }
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (_isSignUp) {
        await _auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
      
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainContainerView()),
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = _mapFirebaseError(e.code);
      });
    } catch (e) {
      setState(() {
        _errorMessage = "Connection error: Unable to reach auth server.";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Minimal Logo Icon
                    Center(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFF1E293B),
                            width: 1.5,
                          ),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: Image.asset(
                          'assets/logo-veloxt-v2.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // Brand Title
                    const Text(
                      "Veloxt",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    
                    // Subtitle
                    const Text(
                      "Enter your operator credentials to access the node.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Color(0xFF64748B),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 40),

                    // Modern Form Layout
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Error Banner
                          if (_errorMessage != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF450A0A).withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFF7F1D1D).withValues(alpha: 0.6),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Padding(
                                    padding: EdgeInsets.only(top: 2.0),
                                    child: Icon(
                                      Icons.error_outline_rounded,
                                      color: Color(0xFFFCA5A5),
                                      size: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(
                                        color: Color(0xFFFCA5A5),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],

                          // Email Input Group
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "EMAIL ADDRESS",
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF94A3B8),
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                ),
                                decoration: const InputDecoration(
                                  hintText: "operator@veloxt.net",
                                  hintStyle: TextStyle(color: Color(0xFF475569)),
                                  filled: true,
                                  fillColor: Color(0xFF0F172A),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFF10B981), width: 1.5),
                                  ),
                                  errorBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
                                  ),
                                  focusedErrorBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return "Email is required";
                                  }
                                  if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(value.trim())) {
                                    return "Enter a valid email address";
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),

                          // Password Input Group
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "AUTHENTICATION KEY",
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF94A3B8),
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: _obscurePassword,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                ),
                                decoration: InputDecoration(
                                  hintText: "••••••••",
                                  hintStyle: const TextStyle(color: Color(0xFF475569)),
                                  filled: true,
                                  fillColor: const Color(0xFF0F172A),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                  border: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                                  ),
                                  focusedBorder: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFF10B981), width: 1.5),
                                  ),
                                  errorBorder: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
                                  ),
                                  focusedErrorBorder: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                    borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
                                  ),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 20,
                                      color: const Color(0xFF64748B),
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscurePassword = !_obscurePassword;
                                      });
                                    },
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return "Password is required";
                                  }
                                  if (value.length < 6) {
                                    return "Minimum 6 characters required";
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 36),

                          // Interactive Action Button
                          _InteractiveButton(
                            onPressed: _isLoading ? null : _handleSubmit,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 52,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _isLoading 
                                    ? const Color(0xFF0F172A)
                                    : const Color(0xFF10B981),
                                borderRadius: BorderRadius.circular(12),
                                border: _isLoading 
                                    ? Border.all(color: const Color(0xFF1E293B), width: 1.2)
                                    : null,
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 18,
                                        width: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.0,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      )
                                    : Text(
                                        _isSignUp ? "Create Account" : "Sign In",
                                        key: ValueKey<bool>(_isSignUp),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                          color: Colors.white,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Clean Mode Switcher Link
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _isSignUp ? "Already have an account? " : "New to the platform? ",
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 13.5,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _isSignUp = !_isSignUp;
                              _errorMessage = null;
                            });
                          },
                          child: Text(
                            _isSignUp ? "Sign In" : "Create Account",
                            style: const TextStyle(
                              color: Color(0xFF10B981),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Custom widget for premium scale feedback on tap
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
