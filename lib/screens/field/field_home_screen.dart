import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../models/site_model.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';
import 'capture_screen.dart';
import 'history_screen.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Field Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: _selectedTab == 0 ? const _FieldSiteList() : const HistoryScreen(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (index) => setState(() => _selectedTab = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'History',
          ),
        ],
      ),
    );
  }
}

class _FieldSiteList extends StatelessWidget {
  const _FieldSiteList();

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
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
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      'Welcome $displayName',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Chip(
                    label: Text('Field Officer'),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('sites')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Text('Failed to load sites: ${snapshot.error}'),
                );
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No sites available. Contact your supervisor.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              final sites = docs
                  .map(
                    (doc) => Site.fromMap({...doc.data(), 'siteId': doc.id}),
                  )
                  .toList();

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                itemCount: sites.length,
                itemBuilder: (context, index) {
                  final site = sites[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.location_pin,
                            color: Colors.blueGrey,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  site.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${site.siteCode} • ${site.riverName}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) =>
                                      CaptureScreen(site: site),
                                ),
                              );
                            },
                            child: const Text('Submit Reading'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
