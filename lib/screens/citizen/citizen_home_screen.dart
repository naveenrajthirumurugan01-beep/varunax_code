import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/citizen_report_model.dart';
import '../../services/auth_service.dart';
import 'citizen_capture_screen.dart';
import 'citizen_history_screen.dart';

String _formatTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

class CitizenHomeScreen extends StatefulWidget {
  const CitizenHomeScreen({super.key});

  @override
  State<CitizenHomeScreen> createState() => _CitizenHomeScreenState();
}

class _CitizenHomeScreenState extends State<CitizenHomeScreen> {
  int _selectedTab = 0;

  Future<void> _logout(BuildContext context) async {
    await AuthService().signOut();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final uid = AuthService().currentUser?.uid;

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
        title: const Text('Citizen Reporter'),
      ),
      body: uid == null
          ? const Center(
              child: Text(
                'Not signed in.',
                style: TextStyle(color: Color(0xFF1A1A1A)),
              ),
            )
          : _selectedTab == 0
          ? _CitizenHome(uid: uid)
          : const CitizenHistoryScreen(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (index) => setState(() => _selectedTab = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment),
            label: 'My Reports',
          ),
        ],
      ),
    );
  }
}

class _CitizenHome extends StatelessWidget {
  const _CitizenHome({required this.uid});

  final String uid;

  void _openCapture(
    BuildContext context,
    Map<String, dynamic> userData,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CitizenCaptureScreen(
          registeredZone: userData['registeredZone'] as String? ?? 'your area',
          registeredZoneRadius:
              (userData['registeredZoneRadius'] as num?)?.toDouble() ?? 5000,
          registeredZoneLatitude: (userData['registeredZoneLatitude'] as num?)
              ?.toDouble(),
          registeredZoneLongitude:
              (userData['registeredZoneLongitude'] as num?)?.toDouble(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, userSnapshot) {
        final userData = userSnapshot.data?.data() ?? const <String, dynamic>{};
        final name = userData['name'] as String? ?? 'Reporter';
        final zone = userData['registeredZone'] as String? ?? 'your area';

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Welcome, $name',
                style: textTheme.headlineLarge?.copyWith(
                  color: const Color(0xFF000000),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.location_on,
                    size: 16,
                    color: AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Registered area: $zone',
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _openCapture(context, userData),
                  icon: const Icon(Icons.report),
                  label: const Text('Report River Condition'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(
                      AppSpacing.minTouchTarget,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'My Reports',
                style: textTheme.headlineMedium?.copyWith(
                  color: const Color(0xFF000000),
                ),
              ),
              const SizedBox(height: 8),
              _RecentReportsPreview(uid: uid),
            ],
          ),
        );
      },
    );
  }
}

/// Compact preview of the citizen's most recent submissions — the full,
/// scrollable list with reviewer notes lives in CitizenHistoryScreen
/// (reachable via the "My Reports" bottom-nav tab).
class _RecentReportsPreview extends StatelessWidget {
  const _RecentReportsPreview({required this.uid});

  final String uid;

  static const int _previewCount = 5;

  Color _statusColor(String status) {
    switch (status) {
      case 'verified':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      case 'flagged':
        return Colors.orange;
      case 'pending':
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'verified':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      case 'flagged':
        return 'Flagged';
      case 'pending':
      default:
        return 'Pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('citizen_reports')
          .where('submittedBy', isEqualTo: uid)
          .orderBy('timestamp', descending: true)
          .limit(_previewCount)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No reports yet — your submissions will show up here.',
              style: TextStyle(color: Color(0xFF1A1A1A)),
            ),
          );
        }

        final reports = docs
            .map(
              (doc) => CitizenReport.fromMap({...doc.data(), 'reportId': doc.id}),
            )
            .toList();

        return Column(
          children: [
            for (final report in reports)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusStandard,
                    ),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: report.photoUrl.isEmpty
                          ? Container(
                              color: AppColors.secondaryContainer,
                              child: const Icon(
                                Icons.image_not_supported,
                                color: AppColors.onSurfaceVariant,
                              ),
                            )
                          : Image.network(
                              report.photoUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Icon(Icons.broken_image),
                            ),
                    ),
                  ),
                  title: Text(
                    report.waterCondition,
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  subtitle: Text(
                    _formatTimestamp(report.timestamp),
                    style: const TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _statusColor(
                        report.verificationStatus,
                      ).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(
                        AppSpacing.radiusPill,
                      ),
                      border: Border.all(
                        color: _statusColor(report.verificationStatus),
                      ),
                    ),
                    child: Text(
                      _statusLabel(report.verificationStatus),
                      style: TextStyle(
                        color: _statusColor(report.verificationStatus),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
