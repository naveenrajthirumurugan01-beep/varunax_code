import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/location_service.dart';

/// Self-service sign-up for the public "Citizen Reporter" role, reached via
/// a text link on the login screen — separate from the staff login flow
/// above it, which stays untouched.
class CitizenRegistrationScreen extends StatefulWidget {
  const CitizenRegistrationScreen({super.key});

  @override
  State<CitizenRegistrationScreen> createState() =>
      _CitizenRegistrationScreenState();
}

class _CitizenRegistrationScreenState
    extends State<CitizenRegistrationScreen> {
  final _authService = AuthService();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _areaController = TextEditingController();

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _areaController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _nameController.text.trim().isNotEmpty &&
      _emailController.text.trim().isNotEmpty &&
      _passwordController.text.isNotEmpty &&
      _areaController.text.trim().isNotEmpty;

  Future<void> _register() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final credential = await _authService.createUserWithEmail(
        _emailController.text.trim(),
        _passwordController.text,
      );
      final uid = credential.user!.uid;

      // Best-effort geofence anchor for the registeredZoneRadius check on
      // the report screen — a zone name alone has no coordinates, so this
      // is captured once here. If location isn't available (permission
      // denied, no GPS fix, etc.), registration still succeeds; the report
      // screen simply skips the geofence check for this account.
      double? latitude;
      double? longitude;
      try {
        final position = await LocationService().getCurrentLocation();
        latitude = position.latitude;
        longitude = position.longitude;
      } catch (_) {
        latitude = null;
        longitude = null;
      }

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'uid': uid,
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'role': 'citizen',
        'assignedSiteIds': <String>[],
        'registeredZone': _areaController.text.trim(),
        'registeredZoneRadius': 5000,
        'registeredZoneLatitude': latitude,
        'registeredZoneLongitude': longitude,
      });

      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/citizen', (route) => false);
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = _messageForAuthError(e.code);
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  String _messageForAuthError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account already exists for this email.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'weak-password':
        return 'Please choose a stronger password (at least 6 characters).';
      default:
        return 'Registration failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Register as Citizen Reporter')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Report river conditions from your area',
                textAlign: TextAlign.center,
                style: textTheme.headlineMedium?.copyWith(
                  color: const Color(0xFF000000),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Your reports are reviewed before being shared with '
                'authorities.',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text('Name', style: textTheme.labelMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                enabled: !_isSubmitting,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Your name'),
              ),
              const SizedBox(height: 20),
              Text('Email', style: textTheme.labelMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                enabled: !_isSubmitting,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'you@example.com'),
              ),
              const SizedBox(height: 20),
              Text('Password', style: textTheme.labelMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                enabled: !_isSubmitting,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: '••••••••'),
              ),
              const SizedBox(height: 20),
              Text('Your Area', style: textTheme.labelMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _areaController,
                enabled: !_isSubmitting,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'e.g. Palavakkam, Chennai',
                ),
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: AppColors.error),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              if (_isSubmitting)
                const Center(child: CircularProgressIndicator())
              else
                ElevatedButton(
                  onPressed: _canSubmit ? _register : null,
                  child: const Text('Register'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
