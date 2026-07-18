import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart' show localeNotifier, setAppLocale;
import '../../models/site_model.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _authService = AuthService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _isSeeding = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final credential = await _authService.signInWithEmail(
        _emailController.text.trim(),
        _passwordController.text,
      );

      final uid = credential.user!.uid;
      // Fire-and-forget, now that we know who's signed in — must never
      // block or fail the login flow if push registration has trouble.
      unawaited(NotificationService().initialize());
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final role = doc.data()?['role'] as String?;

      if (!mounted) return;

      switch (role) {
        case 'field':
          Navigator.pushReplacementNamed(context, '/field');
          break;
        case 'supervisor':
          Navigator.pushReplacementNamed(context, '/supervisor');
          break;
        case 'analyst':
          Navigator.pushReplacementNamed(context, '/analyst');
          break;
        default:
          setState(() {
            _errorMessage = 'No role assigned to this account.';
          });
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = _messageForAuthError(e.code);
      });
    } catch (_) {
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _messageForAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found for this email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      default:
        return 'Login failed. Please try again.';
    }
  }

  // ---- Debug-only: one-tap seeding of the "sites" collection with real
  // dam/river monitoring locations, so the field/supervisor flows have data
  // to work against without needing a separate script. Safe to tap more
  // than once — writes use .set() so they overwrite by siteId. ----

  static final List<Site> _debugSeedSites = [
    Site(
      siteId: 'site_tn_mettur',
      name: 'Mettur Dam',
      siteCode: 'CWC-TN-001',
      riverName: 'Cauvery',
      latitude: 11.8010925,
      longitude: 77.8098951,
      allowedRadius: 300,
      dangerLevel: 120,
      qrCode: 'SITE_TN_METTUR',
      minGaugeHeight: 80,
      maxGaugeHeight: 130,
    ),
    Site(
      siteId: 'site_tn_bhavanisagar',
      name: 'Bhavanisagar Dam',
      siteCode: 'CWC-TN-002',
      riverName: 'Bhavani',
      latitude: 11.4709508,
      longitude: 77.1142817,
      allowedRadius: 300,
      dangerLevel: 105,
      qrCode: 'SITE_TN_BHAVANISAGAR',
      minGaugeHeight: 70,
      maxGaugeHeight: 115,
    ),
    Site(
      siteId: 'site_tn_vaigai',
      name: 'Vaigai Dam',
      siteCode: 'CWC-TN-003',
      riverName: 'Vaigai',
      latitude: 10.0530763,
      longitude: 77.5916688,
      allowedRadius: 300,
      dangerLevel: 71,
      qrCode: 'SITE_TN_VAIGAI',
      minGaugeHeight: 50,
      maxGaugeHeight: 80,
    ),
    Site(
      siteId: 'site_tn_amaravathi',
      name: 'Amaravathi Dam',
      siteCode: 'CWC-TN-004',
      riverName: 'Amaravathi',
      latitude: 10.4182794,
      longitude: 77.2634832,
      allowedRadius: 300,
      dangerLevel: 100,
      qrCode: 'SITE_TN_AMARAVATHI',
      minGaugeHeight: 70,
      maxGaugeHeight: 110,
    ),
    Site(
      siteId: 'site_tn_papanasam',
      name: 'Papanasam Dam',
      siteCode: 'CWC-TN-005',
      riverName: 'Thamirabarani',
      latitude: 8.712,
      longitude: 77.393,
      allowedRadius: 300,
      dangerLevel: 143,
      qrCode: 'SITE_TN_PAPANASAM',
      minGaugeHeight: 100,
      maxGaugeHeight: 150,
    ),
    Site(
      siteId: 'site_kl_idukki',
      name: 'Idukki Dam',
      siteCode: 'CWC-KL-001',
      riverName: 'Periyar',
      latitude: 9.8436187,
      longitude: 76.976231,
      allowedRadius: 300,
      dangerLevel: 2403,
      qrCode: 'SITE_KL_IDUKKI',
      minGaugeHeight: 2300,
      maxGaugeHeight: 2420,
    ),
    Site(
      siteId: 'site_kl_mullaperiyar',
      name: 'Mullaperiyar Dam',
      siteCode: 'CWC-KL-002',
      riverName: 'Periyar',
      latitude: 9.528843,
      longitude: 77.144292,
      allowedRadius: 300,
      dangerLevel: 142,
      qrCode: 'SITE_KL_MULLAPERIYAR',
      minGaugeHeight: 110,
      maxGaugeHeight: 150,
    ),
    Site(
      siteId: 'site_kl_malampuzha',
      name: 'Malampuzha Dam',
      siteCode: 'CWC-KL-003',
      riverName: 'Malampuzha',
      latitude: 10.8388057,
      longitude: 76.690357,
      allowedRadius: 300,
      dangerLevel: 115,
      qrCode: 'SITE_KL_MALAMPUZHA',
      minGaugeHeight: 90,
      maxGaugeHeight: 125,
    ),
    Site(
      siteId: 'site_kl_banasura',
      name: 'Banasura Sagar Dam',
      siteCode: 'CWC-KL-004',
      riverName: 'Karamanthodu',
      latitude: 11.67,
      longitude: 75.957778,
      allowedRadius: 300,
      dangerLevel: 775,
      qrCode: 'SITE_KL_BANASURA',
      minGaugeHeight: 740,
      maxGaugeHeight: 785,
    ),
    Site(
      siteId: 'site_kl_neyyar',
      name: 'Neyyar Dam',
      siteCode: 'CWC-KL-005',
      riverName: 'Neyyar',
      latitude: 8.5340563,
      longitude: 77.1456246,
      allowedRadius: 300,
      dangerLevel: 25,
      qrCode: 'SITE_KL_NEYYAR',
      minGaugeHeight: 15,
      maxGaugeHeight: 30,
    ),
    Site(
      siteId: 'site_ka_krs',
      name: 'Krishna Raja Sagara (KRS) Dam',
      siteCode: 'CWC-KA-001',
      riverName: 'Cauvery',
      latitude: 12.4254763,
      longitude: 76.5724381,
      allowedRadius: 300,
      dangerLevel: 124.8,
      qrCode: 'SITE_KA_KRS',
      minGaugeHeight: 90,
      maxGaugeHeight: 135,
    ),
    Site(
      siteId: 'site_ka_almatti',
      name: 'Almatti Dam',
      siteCode: 'CWC-KA-002',
      riverName: 'Krishna',
      latitude: 16.331,
      longitude: 75.888,
      allowedRadius: 300,
      dangerLevel: 519.6,
      qrCode: 'SITE_KA_ALMATTI',
      minGaugeHeight: 500,
      maxGaugeHeight: 525,
    ),
    Site(
      siteId: 'site_ka_tungabhadra',
      name: 'Tungabhadra Dam',
      siteCode: 'CWC-KA-003',
      riverName: 'Tungabhadra',
      latitude: 15.2616287,
      longitude: 76.3368919,
      allowedRadius: 300,
      dangerLevel: 1633,
      qrCode: 'SITE_KA_TUNGABHADRA',
      minGaugeHeight: 1600,
      maxGaugeHeight: 1645,
    ),
    Site(
      siteId: 'site_ka_bhadra',
      name: 'Bhadra Dam',
      siteCode: 'CWC-KA-004',
      riverName: 'Bhadra',
      latitude: 13.7021742,
      longitude: 75.636595,
      allowedRadius: 300,
      dangerLevel: 657,
      qrCode: 'SITE_KA_BHADRA',
      minGaugeHeight: 630,
      maxGaugeHeight: 665,
    ),
    Site(
      siteId: 'site_ka_linganamakki',
      name: 'Linganamakki Dam',
      siteCode: 'CWC-KA-005',
      riverName: 'Sharavathi',
      latitude: 14.1767166,
      longitude: 74.8496394,
      allowedRadius: 300,
      dangerLevel: 1819,
      qrCode: 'SITE_KA_LINGANAMAKKI',
      minGaugeHeight: 1780,
      maxGaugeHeight: 1830,
    ),
  ];

  Future<void> _seedTestSites() async {
    setState(() {
      _isSeeding = true;
    });

    try {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();
      final sitesCollection = firestore.collection('sites');

      for (final site in _debugSeedSites) {
        batch.set(sitesCollection.doc(site.siteId), site.toMap());
      }

      // Seed test users
      final usersCollection = firestore.collection('users');
      batch.set(usersCollection.doc('yl98KMpDxmOYbuwHCVAJbSr2ymt2'), {
        'uid': 'yl98KMpDxmOYbuwHCVAJbSr2ymt2',
        'name': 'John (Field Officer)',
        'email': 'field@varunax.com',
        'role': 'field',
        'assignedSiteIds': <String>[],
      });
      batch.set(usersCollection.doc('PopWUcpIO7MBAhtiHEjtVS8Mt9u2'), {
        'uid': 'PopWUcpIO7MBAhtiHEjtVS8Mt9u2',
        'name': 'Sarah (Supervisor)',
        'email': 'supervisor@varunax.com',
        'role': 'supervisor',
        'assignedSiteIds': <String>[],
      });
      batch.set(usersCollection.doc('R3xs6CimrgTbECN6LbX9Fvp0CAu1'), {
        'uid': 'R3xs6CimrgTbECN6LbX9Fvp0CAu1',
        'name': 'Alex (Analyst)',
        'email': 'analyst@varunax.com',
        'role': 'analyst',
        'assignedSiteIds': <String>[],
      });

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_debugSeedSites.length} sites added successfully'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to seed sites: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isSeeding = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // Top section: solid primary-blue banner with the app title/subtitle.
          // Padded manually (rather than SafeArea) so the blue extends behind
          // the status bar while its content still clears it.
          Container(
            width: double.infinity,
            color: AppColors.primary,
            padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.paddingOf(context).top + 48,
              24,
              40,
            ),
            child: Column(
              children: [
                Text(
                  l10n.appTitle,
                  textAlign: TextAlign.center,
                  style: textTheme.headlineLarge?.copyWith(
                    color: AppColors.onPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Smart River Water Level Monitoring',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.secondaryContainer,
                  ),
                ),
              ],
            ),
          ),
          // White card with rounded top corners, holding the actual login
          // form. Its own SingleChildScrollView keeps the fields reachable
          // when the keyboard is open, without disturbing the fixed banner.
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(AppSpacing.radiusCard),
                  topRight: Radius.circular(AppSpacing.radiusCard),
                ),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.loginTitle,
                        textAlign: TextAlign.center,
                        style: textTheme.headlineLarge?.copyWith(
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.loginSubtitle,
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const _LanguageSelector(),
                      const SizedBox(height: 24),
                      Text(l10n.emailLabel, style: textTheme.labelMedium),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        enabled: !_isLoading,
                        decoration: const InputDecoration(
                          hintText: 'you@example.com',
                          prefixIcon: Icon(Icons.mail_outline),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(l10n.passwordLabel, style: textTheme.labelMedium),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        enabled: !_isLoading,
                        decoration: const InputDecoration(
                          hintText: '••••••••',
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (_errorMessage != null) ...[
                        Text(
                          _errorMessage!,
                          style: TextStyle(color: AppColors.error),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_isLoading)
                        const Center(child: CircularProgressIndicator())
                      else
                        ElevatedButton(
                          onPressed: _login,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(l10n.loginButton),
                              const SizedBox(width: 8),
                              const Icon(Icons.arrow_forward, size: 18),
                            ],
                          ),
                        ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 16),
                        Center(
                          child: TextButton(
                            onPressed: _isSeeding ? null : _seedTestSites,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.onSurfaceVariant,
                              minimumSize: Size.zero,
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: _isSeeding
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    'Seed Test Sites (Debug)',
                                    style: textTheme.labelSmall?.copyWith(
                                      color: AppColors.onSurfaceVariant,
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal row of language buttons shown above the login fields. Tapping
/// one calls [setAppLocale], which updates [localeNotifier] (rebuilding the
/// whole app immediately via the ValueListenableBuilder in main.dart) and
/// persists the choice to SharedPreferences for next launch.
class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector();

  static const _languages = <(String code, String label)>[
    ('hi', '🇮🇳 हिं'),
    ('en', 'EN'),
    ('ta', 'தமிழ்'),
    ('te', 'తెలుగు'),
    ('kn', 'ಕನ್ನಡ'),
    ('ml', 'മലയാളം'),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: localeNotifier,
      builder: (context, currentLocale, _) {
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (code, label) in _languages)
              _LanguageChip(
                label: label,
                isSelected: currentLocale.languageCode == code,
                onTap: () => setAppLocale(Locale(code)),
              ),
          ],
        );
      },
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? AppColors.primary : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        side: BorderSide(
          color: isSelected ? AppColors.primary : AppColors.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isSelected
                  ? AppColors.onPrimary
                  : AppColors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
