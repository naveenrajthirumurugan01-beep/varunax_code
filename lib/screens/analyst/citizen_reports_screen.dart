import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/citizen_report_model.dart';
import '../../models/reading_model.dart';
import '../../services/auth_service.dart';
import '../../services/push_sender_service.dart';

// Placeholder siteId for readings created from citizen reports — these
// aren't tied to any formal monitoring Site (citizens report from a general
// registered area, not a specific gauge), so there's no real siteId to use.
// Every screen that resolves siteId -> Site already falls back to showing
// the raw siteId string when the lookup misses, so this renders harmly as
// a label rather than crashing anything.
const _citizenReportSiteId = 'citizen_report';

String _formatTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// Analyst-facing verification queue for citizen-submitted river condition
/// reports — separate from (and never touching) the formal field-officer
/// reading review flow in supervisor/review_screen.dart.
class CitizenReportsScreen extends StatelessWidget {
  const CitizenReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Citizen Reports')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('citizen_reports')
            .where('verificationStatus', isEqualTo: 'pending')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            final needsIndex =
                error is FirebaseException &&
                error.code == 'failed-precondition';
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  needsIndex
                      ? 'This queue needs a one-time database index to be '
                            'created before it can load. Please ask your '
                            'administrator to set this up.'
                      : 'Failed to load citizen reports: $error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF1A1A1A)),
                ),
              ),
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
              child: Text(
                'No pending citizen reports',
                style: TextStyle(color: Color(0xFF1A1A1A)),
              ),
            );
          }

          final reports = docs
              .map(
                (doc) =>
                    CitizenReport.fromMap({...doc.data(), 'reportId': doc.id}),
              )
              .toList();

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: reports.length,
            itemBuilder: (context, index) =>
                _PendingReportCard(report: reports[index]),
          );
        },
      ),
    );
  }
}

class _PendingReportCard extends StatefulWidget {
  const _PendingReportCard({required this.report});

  final CitizenReport report;

  @override
  State<_PendingReportCard> createState() => _PendingReportCardState();
}

class _PendingReportCardState extends State<_PendingReportCard> {
  bool _isProcessing = false;

  Future<void> _verify(BuildContext context) async {
    setState(() => _isProcessing = true);
    final report = widget.report;

    try {
      final readingRef = FirebaseFirestore.instance
          .collection('readings')
          .doc();
      final reading = Reading(
        readingId: readingRef.id,
        siteId: _citizenReportSiteId,
        submittedBy: report.submittedBy,
        timestamp: report.timestamp,
        latitude: report.latitude,
        longitude: report.longitude,
        photoUrl: report.photoUrl,
        status: 'pending',
        // No numeric gauge reading exists for a citizen report — "Flooding"
        // is the closest qualitative analog to a formal danger-level alert.
        isAlert: report.waterCondition == 'Flooding',
      );

      final analystUid = AuthService().currentUser?.uid ?? 'unknown';
      final batch = FirebaseFirestore.instance.batch();
      batch.set(readingRef, reading.toMap());
      batch.update(
        FirebaseFirestore.instance
            .collection('citizen_reports')
            .doc(report.reportId),
        {
          'verificationStatus': 'verified',
          'verifiedBy': analystUid,
          'linkedReadingId': readingRef.id,
        },
      );
      await batch.commit();

      unawaited(
        PushSenderService().sendCitizenReportUpdate(
          report.submittedBy,
          'verified',
          null,
        ),
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report verified and reading created')),
      );
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to verify report: $e')));
    }
  }

  Future<void> _flag(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => const _ReviewNoteDialog(
        title: 'Flag Report',
        actionLabel: 'Flag',
      ),
    );
    if (note == null || !context.mounted) return;
    await _updateStatus(context, 'flagged', note);
  }

  Future<void> _reject(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => const _ReviewNoteDialog(
        title: 'Reject Report',
        actionLabel: 'Reject',
      ),
    );
    if (note == null || !context.mounted) return;
    await _updateStatus(context, 'rejected', note);
  }

  Future<void> _updateStatus(
    BuildContext context,
    String status,
    String note,
  ) async {
    setState(() => _isProcessing = true);
    final report = widget.report;

    try {
      final analystUid = AuthService().currentUser?.uid ?? 'unknown';
      await FirebaseFirestore.instance
          .collection('citizen_reports')
          .doc(report.reportId)
          .update({
            'verificationStatus': status,
            'verifiedBy': analystUid,
            'verifierNote': note.isEmpty ? null : note,
          });

      unawaited(
        PushSenderService().sendCitizenReportUpdate(
          report.submittedBy,
          status,
          note.isEmpty ? null : note,
        ),
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Report marked as $status')),
      );
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update report: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: report.photoUrl.isEmpty
                    ? Container(
                        color: AppColors.secondaryContainer,
                        child: const Center(
                          child: Icon(Icons.image_not_supported),
                        ),
                      )
                    : Image.network(
                        report.photoUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const Center(child: Icon(Icons.broken_image)),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    report.submitterZone,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                _ConditionBadge(condition: report.waterCondition),
              ],
            ),
            const SizedBox(height: 4),
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
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(
                  Icons.location_on,
                  size: 12,
                  color: AppColors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '${report.latitude.toStringAsFixed(5)}, '
                  '${report.longitude.toStringAsFixed(5)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (report.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                report.description,
                style: const TextStyle(color: Color(0xFF1A1A1A)),
              ),
            ],
            const SizedBox(height: 12),
            if (_isProcessing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: CircularProgressIndicator(),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _reject(context),
                      icon: const Icon(Icons.close),
                      label: const Text('Reject'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade600,
                        side: BorderSide(color: Colors.red.shade600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _flag(context),
                      icon: const Icon(Icons.flag),
                      label: const Text('Flag'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange.shade700,
                        side: BorderSide(color: Colors.orange.shade700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _verify(context),
                      icon: const Icon(Icons.check),
                      label: const Text('Verify'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ConditionBadge extends StatelessWidget {
  const _ConditionBadge({required this.condition});

  final String condition;

  Color get _color {
    switch (condition) {
      case 'Flooding':
        return Colors.red;
      case 'Rising':
        return Colors.orange;
      case 'Receding':
        return Colors.blue;
      case 'Normal':
      default:
        return Colors.green;
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
        condition,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11),
      ),
    );
  }
}

class _ReviewNoteDialog extends StatefulWidget {
  const _ReviewNoteDialog({required this.title, required this.actionLabel});

  final String title;
  final String actionLabel;

  @override
  State<_ReviewNoteDialog> createState() => _ReviewNoteDialogState();
}

class _ReviewNoteDialogState extends State<_ReviewNoteDialog> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _noteController,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'Note (optional)',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(context).pop(_noteController.text.trim()),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}
