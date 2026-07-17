import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import 'history_screen.dart';
import 'review_screen.dart';

class SupervisorHomeScreen extends StatelessWidget {
  const SupervisorHomeScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    await AuthService().signOut();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;
    final uid = user?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Supervisor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (context, snapshot) {
          final userData = snapshot.data?.data() as Map<String, dynamic>?;
          final userName = userData?['name'] ?? user?.email ?? 'Supervisor';

          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: Colors.blue.shade50,
                          child: Icon(Icons.person, size: 40, color: Colors.blue.shade600),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Welcome, $userName!',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Supervisor Panel',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const ReviewScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.fact_check),
                          label: const Text('Review Readings'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(220, 48),
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const HistoryScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.history),
                          label: const Text('History'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(220, 48),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
