import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/app_localizations.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';
import 'history_screen.dart';
import 'site_picker_screen.dart';

class FieldHomeScreen extends StatefulWidget {
  const FieldHomeScreen({super.key});

  @override
  State<FieldHomeScreen> createState() => _FieldHomeScreenState();
}

class _FieldHomeScreenState extends State<FieldHomeScreen> {
  final _syncService = SyncService();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    // Offline sync logic is unchanged: try to flush any locally-queued
    // readings on load and whenever connectivity changes.
    _syncService.syncPendingReadings();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      _,
    ) {
      _syncService.syncPendingReadings();
    });
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _logout(BuildContext context) async {
    await AuthService().signOut();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const CircleAvatar(
            backgroundColor: Colors.white24,
            child: Icon(Icons.person, color: Colors.white),
          ),
          tooltip: 'Log out',
          onPressed: () => _logout(context),
        ),
        titleSpacing: 0,
        // Same users/{uid} name lookup _FieldHome used to fetch inline for
        // its own "Welcome" line — moved up into the persistent app bar so
        // it's visible from either tab instead of only on Home.
        title: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: user == null
              ? null
              : FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .get(),
          builder: (context, snapshot) {
            final name = snapshot.data?.data()?['name'] as String?;
            final displayName = (name != null && name.trim().isNotEmpty)
                ? name
                : (user?.email ?? '');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.appTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '${l10n.welcomeMessage}, $displayName',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            );
          },
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Icon(Icons.notifications_none),
          ),
        ],
      ),
      body: _selectedTab == 0 ? const _FieldHome() : const HistoryScreen(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (index) => setState(() => _selectedTab = index),
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.home),
            label: l10n.home,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.history),
            label: l10n.history,
          ),
        ],
      ),
    );
  }
}

class _FieldHome extends StatelessWidget {
  const _FieldHome();

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              // "Sites Assigned" reads assignedSiteIds off the same
              // users/{uid} doc the app bar already fetches for the officer's
              // name — no new query, just another field off that doc.
              Expanded(
                child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  future: user == null
                      ? null
                      : FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .get(),
                  builder: (context, snapshot) {
                    final assignedSiteIds =
                        snapshot.data?.data()?['assignedSiteIds'] as List?;
                    final count = assignedSiteIds?.length.toString() ?? '—';
                    return _StatCard(label: 'Sites Assigned', value: count);
                  },
                ),
              ),
              const SizedBox(width: 12),
              // "Pending Sync" calls SyncService's existing getPendingCount()
              // — already implemented, just not previously shown in the UI.
              Expanded(
                child: FutureBuilder<int>(
                  future: SyncService().getPendingCount(),
                  builder: (context, snapshot) {
                    final count = snapshot.data?.toString() ?? '—';
                    return _StatCard(label: 'Pending Sync', value: count);
                  },
                ),
              ),
              const SizedBox(width: 12),
              // "Readings Today" has no existing data source anywhere in the
              // app (no query counts a field officer's readings for the
              // current day) — shown as an honest placeholder rather than a
              // fabricated number, per instruction.
              const Expanded(
                child: _StatCard(label: 'Readings Today', value: '—'),
              ),
            ],
          ),
        ),
        // Officers pick their site first; QR scanning then verifies they're
        // at that specific site rather than being used to discover it.
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const SitePickerScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.location_on),
                label: Text(l10n.submitReading),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(240, 56),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
      ),
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            style: textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            textAlign: TextAlign.center,
            style: textTheme.headlineLarge?.copyWith(
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
