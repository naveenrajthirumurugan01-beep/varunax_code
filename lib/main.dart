import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme.dart';
import 'l10n/app_localizations.dart';
import 'screens/analyst/analyst_dashboard_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/field/field_home_screen.dart';
import 'screens/supervisor/supervisor_home_screen.dart';
import 'services/notification_service.dart';

const _localePrefsKey = 'app_locale';

/// Holds the app's current display language. Read by [VarunaXApp] to drive
/// `MaterialApp.locale`; updated (and persisted) via [setAppLocale] from the
/// language selector on the login screen — a deliberately simple
/// ValueNotifier rather than a full state-management dependency, since this
/// is the only piece of cross-screen UI state the app needs.
final ValueNotifier<Locale> localeNotifier = ValueNotifier(const Locale('en'));

/// Changes the app's display language immediately and remembers the choice
/// for next launch.
Future<void> setAppLocale(Locale locale) async {
  localeNotifier.value = locale;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_localePrefsKey, locale.languageCode);
}

Future<void> _restoreSavedLocale() async {
  final prefs = await SharedPreferences.getInstance();
  final savedCode = prefs.getString(_localePrefsKey);
  if (savedCode != null) {
    localeNotifier.value = Locale(savedCode);
  }
}

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
  await _restoreSavedLocale();
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
    return ValueListenableBuilder<Locale>(
      valueListenable: localeNotifier,
      builder: (context, locale, _) {
        return MaterialApp(
          title: 'Varuna X',
          theme: AppTheme.lightTheme,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          initialRoute: '/login',
          routes: {
            '/login': (context) => const LoginScreen(),
            '/field': (context) => const FieldHomeScreen(),
            '/supervisor': (context) => const SupervisorHomeScreen(),
            '/analyst': (context) => const AnalystDashboardScreen(),
          },
        );
      },
    );
  }
}
