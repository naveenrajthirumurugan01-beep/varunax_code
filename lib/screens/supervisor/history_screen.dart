import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../services/user_lookup_service.dart';
import '../../utils/report_generator.dart';

enum _StatusFilter { all, approved, rejected, pending }

extension on _StatusFilter {
  String get label {
    switch (this) {
      case _StatusFilter.all:
        return 'All';
      case _StatusFilter.approved:
        return 'Approved';
      case _StatusFilter.rejected:
        return 'Rejected';
      case _StatusFilter.pending:
        return 'Pending';
    }
  }

  String? get statusValue {
    switch (this) {
      case _StatusFilter.all:
        return null;
      case _StatusFilter.approved:
        return 'approved';
      case _StatusFilter.rejected:
        return 'rejected';
      case _StatusFilter.pending:
        return 'pending';
    }
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  _StatusFilter _filter = _StatusFilter.all;

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('readings')
        .orderBy('timestamp', descending: true);
    final statusValue = _filter.statusValue;
    if (statusValue != null) {
      query = query.where('status', isEqualTo: statusValue);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('All Readings')),
      // Sites are fetched once here (rather than per-card) so _HistoryCard
      // can build a reading summary without an extra Firestore read per
      // card — mirrors the siteById pattern already used in review_screen.
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('sites').snapshots(),
        builder: (context, sitesSnapshot) {
          final siteDocs = sitesSnapshot.data?.docs ?? [];
          final siteById = {
            for (final doc in siteDocs)
              doc.id: Site.fromMap({...doc.data(), 'siteId': doc.id}),
          };

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Activity Log',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(color: const Color(0xFF000000)),
                      ),
                    ),
                    // Visual only for now — no additional filter logic
                    // behind this yet.
                    TextButton(
                      onPressed: () {},
                      child: const Text('More Filters'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final filter in _StatusFilter.values) ...[
                        _FilterPill(
                          label: filter.label,
                          selected: _filter == filter,
                          onTap: () => setState(() => _filter = filter),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: query.snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Failed to load readings: ${snapshot.error}',
                          style: const TextStyle(color: Color(0xFF1A1A1A)),
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
                          'No readings found',
                          style: TextStyle(color: Color(0xFF1A1A1A)),
                        ),
                      );
                    }

                    final readings = docs
                        .map(
                          (doc) => Reading.fromMap({
                            ...doc.data(),
                            'readingId': doc.id,
                          }),
                        )
                        .toList();

                    return ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: readings.length,
                      itemBuilder: (context, index) => _HistoryCard(
                        reading: readings[index],
                        site: siteById[readings[index].siteId],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.secondaryContainer,
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.onPrimary : AppColors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.reading, required this.site});

  final Reading reading;
  final Site? site;

  String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  // Same mismatch formula _LevelComparison already applies below (Dart
  // privacy is per-library/file, not per-class, so its threshold constant
  // is reachable here without duplicating the number).
  bool get _isHighVariance {
    final manual = reading.manualLevel;
    final ai = reading.aiDetectedLevel;
    if (manual == null || ai == null) return false;
    return (manual - ai).abs() > _LevelComparison._mismatchThreshold;
  }

  Color? get _accentColor {
    if (reading.status == 'rejected') return Colors.red;
    if (_isHighVariance) return Colors.orange;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final accent = _accentColor;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: accent == null
            ? null
            : BoxDecoration(border: Border(left: BorderSide(color: accent, width: 4))),
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
              child: SizedBox(
                width: 64,
                height: 64,
                child: Image.network(
                  reading.photoUrl,
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
                      Expanded(child: _SiteNameLabel(siteId: reading.siteId)),
                      _StatusBadge(status: reading.status),
                    ],
                  ),
                  const SizedBox(height: 2),
                  _SubmitterLabel(
                    uid: reading.submittedBy,
                    timeText: _formatTimestamp(reading.timestamp),
                  ),
                  _LevelComparison(reading: reading),
                  if (reading.supervisorNote != null &&
                      reading.supervisorNote!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Note: ${reading.supervisorNote}',
                      style: const TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                  if (site != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Summary',
                      style: textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      generateReadingSummary(reading, site!, null),
                      style: textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  Color _color() {
    switch (status) {
      case 'approved':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      case 'pending':
      default:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(
        status[0].toUpperCase() + status.substring(1),
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}

class _SiteNameLabel extends StatelessWidget {
  const _SiteNameLabel({required this.siteId});

  final String siteId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future:
          FirebaseFirestore.instance.collection('sites').doc(siteId).get(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final siteName = data != null ? Site.fromMap(data).name : siteId;
        return Text(
          siteName,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Color(0xFF1A1A1A),
          ),
        );
      },
    );
  }
}

class _SubmitterLabel extends StatelessWidget {
  const _SubmitterLabel({required this.uid, this.timeText});

  final String uid;
  final String? timeText;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: UserLookupService.getDisplayName(uid),
      builder: (context, snapshot) {
        final displayName = snapshot.data ?? uid;
        final text = timeText == null
            ? 'Submitted by: $displayName'
            : 'Officer: $displayName • $timeText';
        return Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppColors.onSurfaceVariant,
          ),
        );
      },
    );
  }
}

class _LevelComparison extends StatelessWidget {
  const _LevelComparison({required this.reading});

  final Reading reading;

  static const double _mismatchThreshold = 0.5;

  @override
  Widget build(BuildContext context) {
    final manual = reading.manualLevel;
    final ai = reading.aiDetectedLevel;

    if (manual == null && ai == null) {
      return const SizedBox.shrink();
    }

    if (manual != null && ai != null) {
      final mismatch = (manual - ai).abs() > _mismatchThreshold;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mismatch) ...[
              const _MismatchBanner(),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: _ComparisonCell(
                    label: 'MANUAL INPUT',
                    value: '${manual.toStringAsFixed(1)}m',
                    highlight: mismatch,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ComparisonCell(
                    label: 'AI DETECTED',
                    value: '${ai.toStringAsFixed(1)}m',
                    highlight: mismatch,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (manual != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _ComparisonCell(
          label: 'MANUAL INPUT',
          value: '${manual.toStringAsFixed(1)}m',
          highlight: false,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _ComparisonCell(
        label: 'AI DETECTED',
        value: '${ai!.toStringAsFixed(1)}m',
        highlight: false,
      ),
    );
  }
}

class _MismatchBanner extends StatelessWidget {
  const _MismatchBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange.shade800,
            size: 18,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'AI and manual readings differ significantly',
              style: TextStyle(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComparisonCell extends StatelessWidget {
  const _ComparisonCell({
    required this.label,
    required this.value,
    required this.highlight,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: highlight ? Colors.orange.shade50 : AppColors.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: highlight ? Colors.orange.shade800 : AppColors.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
