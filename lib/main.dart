import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'views/splash_view.dart';
import 'theme/theme_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Force full-screen immersive mode — hide Android status bar & navigation bar
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  
  // Initialize Firebase using the shared web project configurations
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyBdIpYQayK8u-jH9lnCk_OQKAnDb3R5_JE",
      authDomain: "live-streaming-tour.firebaseapp.com",
      projectId: "live-streaming-tour",
      storageBucket: "live-streaming-tour.firebasestorage.app",
      messagingSenderId: "513758443707",
      appId: "1:513758443707:android:be7b0b2e8cfad17f39446d",
    ),
  );
  
  runApp(const SrtStreamApp());
}

class SrtStreamApp extends StatelessWidget {
  const SrtStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeManager.accentColorNotifier,
      builder: (context, child) {
        final activeAccent = ThemeManager.accentColor;
        return MaterialApp(
          title: 'Veloxt',
          debugShowCheckedModeBanner: false,
          theme: ThemeManager.getTheme(activeAccent),
          home: const SplashView(),
        );
      },
    );
  }
}

