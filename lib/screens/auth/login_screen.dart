import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/site_model.dart';
import '../../services/auth_service.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Varuna X',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  enabled: !_isLoading,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  enabled: !_isLoading,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                if (_errorMessage != null) ...[
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
                if (_isLoading)
                  const Center(child: CircularProgressIndicator())
                else
                  ElevatedButton(
                    onPressed: _login,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Log In'),
                    ),
                  ),
                if (kDebugMode) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isSeeding ? null : _seedTestSites,
                    child: _isSeeding
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Seed Test Sites (Debug)'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
