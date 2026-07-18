// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'VARUNA X';

  @override
  String get loginTitle => 'Secure Access';

  @override
  String get loginSubtitle => 'Enter your credentials to monitor field data';

  @override
  String get emailLabel => 'Email Address';

  @override
  String get passwordLabel => 'Password';

  @override
  String get loginButton => 'Login';

  @override
  String get fieldDashboardTitle => 'Field Dashboard';

  @override
  String get welcomeMessage => 'Welcome';

  @override
  String get submitReading => 'Submit Reading';

  @override
  String get siteInformation => 'Site Information';

  @override
  String get waterLevelReading => 'Water Level Reading';

  @override
  String get enterLevelHint => 'Enter level in meters';

  @override
  String get dangerLevel => 'Danger Level';

  @override
  String get aiSuggested => 'AI Suggested — please verify';

  @override
  String get submitReadingButton => 'Submit Reading';

  @override
  String get retake => 'Retake';

  @override
  String get supervisorTitle => 'Supervisor';

  @override
  String get reviewReadings => 'Review Readings';

  @override
  String get approve => 'Approve';

  @override
  String get reject => 'Reject';

  @override
  String get analystDashboard => 'Analyst Dashboard';

  @override
  String get history => 'History';

  @override
  String get home => 'Home';

  @override
  String get withinGeofence => 'Within geofence range';

  @override
  String get outsideGeofence => 'You are outside the geofence';

  @override
  String get scanQrCode => 'Scan QR Code';

  @override
  String get gaugePostReading => 'Gauge Post Reading';

  @override
  String get phStripReading => 'pH Strip Reading';

  @override
  String get waterQuality => 'Water Quality';

  @override
  String get safe => 'Safe';

  @override
  String get caution => 'Caution';

  @override
  String get unsafe => 'Unsafe';
}
