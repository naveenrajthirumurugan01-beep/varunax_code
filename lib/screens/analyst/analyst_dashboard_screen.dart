import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../services/auth_service.dart';

const _statusOptions = ['All', 'Pending', 'Approved', 'Rejected'];

Color _statusColor(String status) {
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

String _formatTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

class AnalystDashboardScreen extends StatefulWidget {
  const AnalystDashboardScreen({super.key});

  @override
  State<AnalystDashboardScreen> createState() => _AnalystDashboardScreenState();
}

class _AnalystDashboardScreenState extends State<AnalystDashboardScreen> {
  String _statusFilter = 'All';
  String? _siteFilterId;

  Future<void> _logout(BuildContext context) async {
    await AuthService().signOut();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  void _showDetail(BuildContext context, Reading reading, String siteName) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _ReadingDetailDialog(reading: reading, siteName: siteName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analyst Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('sites').snapshots(),
        builder: (context, sitesSnapshot) {
          final siteDocs = sitesSnapshot.data?.docs ?? [];
          final sites = siteDocs
              .map((doc) => Site.fromMap({...doc.data(), 'siteId': doc.id}))
              .toList();
          final siteNameById = {for (final s in sites) s.siteId: s.name};

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('readings')
                .orderBy('timestamp', descending: true)
                .limit(100)
                .snapshots(),
            builder: (context, readingsSnapshot) {
              if (readingsSnapshot.hasError) {
                return Center(
                  child: Text(
                    'Failed to load readings: ${readingsSnapshot.error}',
                  ),
                );
              }
              if (readingsSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = readingsSnapshot.data?.docs ?? [];
              final readings = docs
                  .map(
                    (doc) =>
                        Reading.fromMap({...doc.data(), 'readingId': doc.id}),
                  )
                  .toList();

              final filteredReadings = readings.where((r) {
                final statusMatches =
                    _statusFilter == 'All' ||
                    r.status.toLowerCase() == _statusFilter.toLowerCase();
                final siteMatches =
                    _siteFilterId == null || r.siteId == _siteFilterId;
                return statusMatches && siteMatches;
              }).toList();

              return Column(
                children: [
                  _StatsRow(readings: readings),
                  _FilterRow(
                    statusFilter: _statusFilter,
                    siteFilterId: _siteFilterId,
                    sites: sites,
                    onStatusChanged: (value) =>
                        setState(() => _statusFilter = value),
                    onSiteChanged: (value) =>
                        setState(() => _siteFilterId = value),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: filteredReadings.isEmpty
                        ? const Center(
                            child: Text('No readings match the current filter'),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: filteredReadings.length,
                            itemBuilder: (context, index) {
                              final reading = filteredReadings[index];
                              final siteName =
                                  siteNameById[reading.siteId] ??
                                  reading.siteId;
                              return _ReadingCard(
                                reading: reading,
                                siteName: siteName,
                                onTap: () =>
                                    _showDetail(context, reading, siteName),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.readings});

  final List<Reading> readings;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final todayCount = readings
        .where(
          (r) =>
              r.timestamp.year == now.year &&
              r.timestamp.month == now.month &&
              r.timestamp.day == now.day,
        )
        .length;
    final approvedCount = readings
        .where((r) => r.status.toLowerCase() == 'approved')
        .length;
    final pendingCount = readings
        .where((r) => r.status.toLowerCase() == 'pending')
        .length;
    final siteCount = readings.map((r) => r.siteId).toSet().length;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: _StatCard(
              label: 'Today',
              value: todayCount,
              color: Colors.blue,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _StatCard(
              label: 'Approved',
              value: approvedCount,
              color: Colors.green,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _StatCard(
              label: 'Pending',
              value: pendingCount,
              color: Colors.orange,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _StatCard(
              label: 'Sites',
              value: siteCount,
              color: Colors.purple,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.statusFilter,
    required this.siteFilterId,
    required this.sites,
    required this.onStatusChanged,
    required this.onSiteChanged,
  });

  final String statusFilter;
  final String? siteFilterId;
  final List<Site> sites;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<String?> onSiteChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Status',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                DropdownButton<String>(
                  value: statusFilter,
                  isExpanded: true,
                  items: _statusOptions
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) onStatusChanged(value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Site',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                DropdownButton<String?>(
                  value: siteFilterId,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<String?>(child: Text('All sites')),
                    ...sites.map(
                      (s) => DropdownMenuItem<String?>(
                        value: s.siteId,
                        child: Text(s.name),
                      ),
                    ),
                  ],
                  onChanged: onSiteChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({
    required this.reading,
    required this.siteName,
    required this.onTap,
  });

  final Reading reading;
  final String siteName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(reading.status);
    final level = reading.manualLevel ?? reading.aiDetectedLevel;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        title: Text(
          siteName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(_formatTimestamp(reading.timestamp)),
            if (level != null) Text('Level: $level'),
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color),
          ),
          child: Text(
            reading.status,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadingDetailDialog extends StatelessWidget {
  const _ReadingDetailDialog({required this.reading, required this.siteName});

  final Reading reading;
  final String siteName;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(reading.status);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(siteName, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (reading.photoUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      reading.photoUrl,
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox(
                            height: 160,
                            child: Center(
                              child: Icon(Icons.broken_image, size: 48),
                            ),
                          ),
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const SizedBox(
                          height: 160,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      },
                    ),
                  )
                else
                  const SizedBox(
                    height: 80,
                    child: Center(child: Text('Photo not yet uploaded')),
                  ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color),
                  ),
                  child: Text(
                    reading.status,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: 'Submitted',
                  value: _formatTimestamp(reading.timestamp),
                ),
                _DetailRow(label: 'Submitted by', value: reading.submittedBy),
                _DetailRow(
                  label: 'Location',
                  value:
                      '${reading.latitude.toStringAsFixed(5)}, '
                      '${reading.longitude.toStringAsFixed(5)}',
                ),
                if (reading.manualLevel != null)
                  _DetailRow(
                    label: 'Manual level',
                    value: '${reading.manualLevel}',
                  ),
                if (reading.aiDetectedLevel != null)
                  _DetailRow(
                    label: 'AI detected level',
                    value: '${reading.aiDetectedLevel}',
                  ),
                if (reading.supervisorNote != null &&
                    reading.supervisorNote!.isNotEmpty)
                  _DetailRow(
                    label: 'Supervisor note',
                    value: reading.supervisorNote!,
                  ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
