import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/citizen_report_model.dart';
import '../../services/auth_service.dart';

String _formatTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// The citizen reporter's own submission history — every report they've
/// filed, newest first, with its verification outcome.
class CitizenHistoryScreen extends StatelessWidget {
  const CitizenHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = AuthService().currentUser?.uid;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'My Reports',
            style: textTheme.headlineLarge?.copyWith(
              color: const Color(0xFF000000),
            ),
          ),
        ),
        Expanded(
          child: uid == null
              ? const Center(
                  child: Text(
                    'Not signed in.',
                    style: TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                )
              : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('citizen_reports')
                      .where('submittedBy', isEqualTo: uid)
                      .orderBy('timestamp', descending: true)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      final error = snapshot.error;
                      // Firestore throws failed-precondition when a
                      // composite index this query needs doesn't exist yet
                      // — surfaced clearly rather than a raw exception
                      // string or a crash.
                      final needsIndex =
                          error is FirebaseException &&
                          error.code == 'failed-precondition';
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            needsIndex
                                ? 'Your report history needs a one-time '
                                      'database index to be created before '
                                      'it can load. Please ask your '
                                      'administrator to set this up.'
                                : 'Failed to load your reports: $error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFF1A1A1A)),
                          ),
                        ),
                      );
                    }
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    final docs = snapshot.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return const Center(
                        child: Text(
                          'No reports yet',
                          style: TextStyle(color: Color(0xFF1A1A1A)),
                        ),
                      );
                    }

                    final reports = docs
                        .map(
                          (doc) => CitizenReport.fromMap({
                            ...doc.data(),
                            'reportId': doc.id,
                          }),
                        )
                        .toList();

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: reports.length,
                      itemBuilder: (context, index) =>
                          _CitizenReportCard(report: reports[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _VerificationBadge extends StatelessWidget {
  const _VerificationBadge({required this.status});

  final String status;

  Color get _color {
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

  String get _label {
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
    final color = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: color),
      ),
      child: Text(
        _label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11),
      ),
    );
  }
}

class _CitizenReportCard extends StatelessWidget {
  const _CitizenReportCard({required this.report});

  final CitizenReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    AppSpacing.radiusStandard,
                  ),
                  child: SizedBox(
                    width: 64,
                    height: 64,
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
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              report.waterCondition,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: Color(0xFF1A1A1A),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _VerificationBadge(
                            status: report.verificationStatus,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(
                            Icons.calendar_today,
                            size: 12,
                            color: AppColors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatTimestamp(report.timestamp),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (report.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          report.description,
                          style: const TextStyle(color: Color(0xFF1A1A1A)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (report.verificationStatus == 'verified') ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(
                    AppSpacing.radiusStandard,
                  ),
                  border: Border.all(color: Colors.green.shade100),
                ),
                child: Row(
                  children: [
                    Icon(Icons.verified, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '✓ Report accepted by authorities',
                        style: TextStyle(
                          color: Colors.green.shade900,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if ((report.verificationStatus == 'rejected' ||
                    report.verificationStatus == 'flagged') &&
                report.verifierNote != null &&
                report.verifierNote!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(
                    AppSpacing.radiusStandard,
                  ),
                  border: Border.all(color: Colors.red.shade100),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.message_outlined,
                      size: 16,
                      color: Colors.red.shade700,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reviewer Note',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.red.shade700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            report.verifierNote!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red.shade900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
