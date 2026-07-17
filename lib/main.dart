import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/theme.dart';
import 'screens/analyst/analyst_dashboard_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/field/field_home_screen.dart';
import 'screens/supervisor/supervisor_home_screen.dart';
import 'services/notification_service.dart';

const _desktopFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCV1hBvl6Cb7XncUTgQE6S7Xx5vWw265L0',
  appId: '1:68017591462:web:3f93ff87c95a621533d067',
  messagingSenderId: '68017591462',
  projectId: 'varuna-x-28174',
  storageBucket: 'varuna-x-28174.firebasestorage.app',
  authDomain: 'varuna-x-28174.firebaseapp.com',
);

bool get _isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  if (kIsWeb) {
    await Firebase.initializeApp(options: _desktopFirebaseOptions);
  } else if (_isDesktopPlatform) {
    await Firebase.initializeApp(options: _desktopFirebaseOptions);
  } else {
    await Firebase.initializeApp();
  }
  // Fire-and-forget: covers a user who's already signed in from a previous
  // session reopening the app. NotificationService itself skips web and any
  // platform firebase_messaging doesn't support, and must never block
  // startup or fail app launch if push registration has trouble.
  unawaited(NotificationService().initialize());
  runApp(const VarunaXApp());
}

class VarunaXApp extends StatelessWidget {
  const VarunaXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Varuna X',
      theme: AppTheme.lightTheme,
      initialRoute: '/login',
      routes: {
        '/login': (context) => const LoginScreen(),
        '/field': (context) => const FieldHomeScreen(),
        '/supervisor': (context) => const SupervisorHomeScreen(),
        '/analyst': (context) => const AnalystDashboardScreen(),
      },
    );
  }
}
