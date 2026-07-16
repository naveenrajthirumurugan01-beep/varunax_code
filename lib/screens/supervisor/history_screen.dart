import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/reading_model.dart';
import '../../models/site_model.dart';

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
      appBar: AppBar(title: const Text('Reading History')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: DropdownButtonFormField<_StatusFilter>(
              initialValue: _filter,
              decoration: const InputDecoration(
                labelText: 'Filter',
                border: OutlineInputBorder(),
              ),
              items: _StatusFilter.values
                  .map(
                    (filter) => DropdownMenuItem(
                      value: filter,
                      child: Text(filter.label),
                    ),
                  )
                  .toList(),
              onChanged: (filter) {
                if (filter == null) return;
                setState(() {
                  _filter = filter;
                });
              },
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: query.snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Failed to load readings: ${snapshot.error}'),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(child: Text('No readings found'));
                }

                final readings = docs
                    .map(
                      (doc) =>
                          Reading.fromMap({...doc.data(), 'readingId': doc.id}),
                    )
                    .toList();

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: readings.length,
                  itemBuilder: (context, index) =>
                      _HistoryCard(reading: readings[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.reading});

  final Reading reading;

  String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

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
              children: [
                Expanded(child: _SiteNameLabel(siteId: reading.siteId)),
                _StatusBadge(status: reading.status),
              ],
            ),
            const SizedBox(height: 4),
            Text('Submitted: ${_formatTimestamp(reading.timestamp)}'),
            _LevelComparison(reading: reading),
            if (reading.supervisorNote != null &&
                reading.supervisorNote!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Note: ${reading.supervisorNote}',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
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
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'AI: ${ai.toStringAsFixed(1)}m | '
              'Officer: ${manual.toStringAsFixed(1)}m',
              style: TextStyle(
                fontWeight: mismatch ? FontWeight.bold : FontWeight.normal,
                color: mismatch ? Colors.red.shade700 : null,
              ),
            ),
            if (mismatch) ...[
              const SizedBox(width: 6),
              const Text('⚠️ Mismatch'),
            ],
          ],
        ),
      );
    }

    if (manual != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('Manual level: ${manual.toStringAsFixed(1)}m'),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('AI-detected level: ${ai!.toStringAsFixed(1)}m'),
    );
  }
}
