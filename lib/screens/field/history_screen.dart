import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../services/auth_service.dart';

enum _StatusFilter { approved, pending, rejected }

extension on _StatusFilter {
  String get label {
    switch (this) {
      case _StatusFilter.approved:
        return 'Approved';
      case _StatusFilter.pending:
        return 'Pending';
      case _StatusFilter.rejected:
        return 'Rejected';
    }
  }

  String get value {
    switch (this) {
      case _StatusFilter.approved:
        return 'approved';
      case _StatusFilter.pending:
        return 'pending';
      case _StatusFilter.rejected:
        return 'rejected';
    }
  }

  Color get dotColor {
    switch (this) {
      case _StatusFilter.approved:
        return Colors.green;
      case _StatusFilter.pending:
        return Colors.amber.shade700;
      case _StatusFilter.rejected:
        return Colors.red;
    }
  }
}

String _formatTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// The field officer's own reading history — pulled from the `readings`
/// collection, filtered to submittedBy == the signed-in user and ordered by
/// timestamp, with a status pill filter on top.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  _StatusFilter _filter = _StatusFilter.pending;

  @override
  Widget build(BuildContext context) {
    final uid = AuthService().currentUser?.uid;
    final textTheme = Theme.of(context).textTheme;

    // Sites are fetched once here (same siteById pattern already used on
    // the supervisor/analyst screens) so each card can show site name/river
    // without a per-card Firestore read.
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('sites').snapshots(),
      builder: (context, sitesSnapshot) {
        final siteDocs = sitesSnapshot.data?.docs ?? [];
        final siteById = {
          for (final doc in siteDocs)
            doc.id: Site.fromMap({...doc.data(), 'siteId': doc.id}),
        };

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Readings',
                    style: textTheme.headlineLarge?.copyWith(
                      color: const Color(0xFF000000),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Review and manage your field data submissions.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final filter in _StatusFilter.values) ...[
                    Expanded(
                      child: _StatusFilterPill(
                        filter: filter,
                        selected: _filter == filter,
                        onTap: () => setState(() => _filter = filter),
                      ),
                    ),
                    if (filter != _StatusFilter.values.last)
                      const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
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
                          .collection('readings')
                          .where('submittedBy', isEqualTo: uid)
                          .orderBy('timestamp', descending: true)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          final error = snapshot.error;
                          // Firestore throws failed-precondition when a
                          // composite index this query needs doesn't exist
                          // yet — surfaced clearly rather than a raw
                          // exception string or a crash.
                          final needsIndex =
                              error is FirebaseException &&
                              error.code == 'failed-precondition';
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                needsIndex
                                    ? 'Your reading history needs a one-time '
                                          'database index to be created '
                                          'before it can load. Please ask '
                                          'your administrator to set this '
                                          'up.'
                                    : 'Failed to load your readings: $error',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Color(0xFF1A1A1A)),
                              ),
                            ),
                          );
                        }
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        final docs = snapshot.data?.docs ?? [];
                        final readings = docs
                            .map(
                              (doc) => Reading.fromMap({
                                ...doc.data(),
                                'readingId': doc.id,
                              }),
                            )
                            .where(
                              (r) =>
                                  r.status.toLowerCase() == _filter.value,
                            )
                            .toList();

                        if (readings.isEmpty) {
                          return Center(
                            child: Text(
                              'No ${_filter.label.toLowerCase()} readings yet',
                              style: const TextStyle(color: Color(0xFF1A1A1A)),
                            ),
                          );
                        }

                        return ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: readings.length,
                          itemBuilder: (context, index) =>
                              _ReadingHistoryCard(
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
    );
  }
}

class _StatusFilterPill extends StatelessWidget {
  const _StatusFilterPill({
    required this.filter,
    required this.selected,
    required this.onTap,
  });

  final _StatusFilter filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.secondaryContainer,
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: filter.dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              filter.label,
              style: TextStyle(
                color: selected ? AppColors.onPrimary : AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  Color get _color {
    switch (status.toLowerCase()) {
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
    final color = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: color),
      ),
      child: Text(
        status.isEmpty ? status : status[0].toUpperCase() + status.substring(1),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ReadingHistoryCard extends StatelessWidget {
  const _ReadingHistoryCard({required this.reading, required this.site});

  final Reading reading;
  final Site? site;

  @override
  Widget build(BuildContext context) {
    final level = reading.manualLevel ?? reading.aiDetectedLevel;
    final hasNote =
        reading.status.toLowerCase() == 'rejected' &&
        reading.supervisorNote != null &&
        reading.supervisorNote!.isNotEmpty;

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
                    child: reading.photoUrl.isEmpty
                        ? Container(
                            color: AppColors.secondaryContainer,
                            child: const Icon(
                              Icons.image_not_supported,
                              color: AppColors.onSurfaceVariant,
                            ),
                          )
                        : Image.network(
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
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              site?.name ?? reading.siteId,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.primary,
                                fontSize: 15,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _StatusPill(status: reading.status),
                        ],
                      ),
                      if (site != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          site!.riverName,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        level != null ? '${level.toStringAsFixed(1)}m' : '—',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppColors.onSurface,
                        ),
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
                            _formatTimestamp(reading.timestamp),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (hasNote) ...[
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
                            'Supervisor Note',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.red.shade700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            reading.supervisorNote!,
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
