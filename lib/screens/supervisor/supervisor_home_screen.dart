import 'package:flutter/material.dart';

import '../../core/theme.dart';
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

  void _openReview(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const ReviewScreen()));
  }

  void _openHistory(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const HistoryScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

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
        title: Row(
          children: [
            const Text('VARUNA X', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
              ),
              child: const Text(
                'SUPERVISOR',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Icon(Icons.notifications_none),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Good Morning, Supervisor.', style: textTheme.headlineLarge),
            const SizedBox(height: 4),
            Text(
              'Here is your daily oversight summary.',
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            // Pending count isn't available here without a new Firestore
            // query (this screen doesn't currently fetch readings at all —
            // only review_screen.dart's own StreamBuilder does), so the
            // badge is omitted rather than showing a fabricated number.
            _HomeActionCard(
              icon: Icons.checklist,
              title: 'Review Readings',
              onTap: () => _openReview(context),
            ),
            const SizedBox(height: 16),
            _HomeActionCard(
              icon: Icons.history,
              title: 'History',
              onTap: () => _openHistory(context),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        // No tab state to track here — this screen IS "Home", so it's
        // always shown selected; tapping "History" triggers the exact same
        // navigation the History card above already does.
        currentIndex: 0,
        onTap: (index) {
          if (index == 1) _openHistory(context);
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}

class _HomeActionCard extends StatelessWidget {
  const _HomeActionCard({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.secondaryContainer,
                child: Icon(icon, color: AppColors.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
