import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../models/weather_reading_model.dart';
import '../../services/auth_service.dart';
import '../../services/weather_service.dart';

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

String _formatShortDate(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.month)}/${two(dt.day)}';
}

String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) {
    return '${diff.inSeconds}s ago';
  }
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  }
  return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
}

class AnalystDashboardScreen extends StatefulWidget {
  const AnalystDashboardScreen({super.key});

  @override
  State<AnalystDashboardScreen> createState() => _AnalystDashboardScreenState();
}

class _AnalystDashboardScreenState extends State<AnalystDashboardScreen> {
  String _statusFilter = 'All';
  String? _siteFilterId;

  final Set<String> _seenAlertIds = {};
  bool _alertsInitialized = false;

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

  // Compares this snapshot of active alerts against the previous one
  // (tracked via _seenAlertIds) and pops up a dialog for any reading that
  // wasn't there before. The very first snapshot just establishes the
  // baseline — otherwise every pre-existing alert would trigger a popup the
  // moment this screen opens.
  void _handleAlertReadings(
    List<Reading> alertReadings,
    Map<String, Site> siteById,
  ) {
    if (!_alertsInitialized) {
      _alertsInitialized = true;
      _seenAlertIds.addAll(alertReadings.map((r) => r.readingId));
      return;
    }

    final newAlerts = alertReadings
        .where((r) => !_seenAlertIds.contains(r.readingId))
        .toList();
    if (newAlerts.isEmpty) return;

    _seenAlertIds.addAll(newAlerts.map((r) => r.readingId));

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (final reading in newAlerts) {
        if (!mounted) return;
        final siteName = siteById[reading.siteId]?.name ?? reading.siteId;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('⚠️ Water Level Alert'),
            content: Text(
              '⚠️ Water Level Alert — $siteName has exceeded its danger '
              'threshold',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;
    final uid = user?.uid;

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
          final siteById = {for (final s in sites) s.siteId: s};

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            // Equality filter only (no orderBy on a second field), same
            // convention used elsewhere in this app to avoid requiring a
            // composite Firestore index — sorted client-side below.
            stream: FirebaseFirestore.instance
                .collection('readings')
                .where('isAlert', isEqualTo: true)
                .snapshots(),
            builder: (context, alertSnapshot) {
              final alertDocs = alertSnapshot.data?.docs ?? [];
              final alertReadings =
                  alertDocs
                      .map(
                        (doc) => Reading.fromMap({
                          ...doc.data(),
                          'readingId': doc.id,
                        }),
                      )
                      .toList()
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

              _handleAlertReadings(alertReadings, siteById);

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
                  if (readingsSnapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = readingsSnapshot.data?.docs ?? [];
                  final readings = docs
                      .map(
                        (doc) => Reading.fromMap({
                          ...doc.data(),
                          'readingId': doc.id,
                        }),
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

                  // The whole body scrolls as one column now: the trend
                  // charts + weather section pushed total fixed-height
                  // content past the viewport on smaller screens, and a
                  // Column can't shrink non-Expanded children to fit, so it
                  // overflowed at the bottom instead of scrolling. The
                  // reading list below is no longer its own Expanded/scrolling
                  // region — it's shrink-wrapped into this single scroll view
                  // so nothing gets clipped regardless of content height.
                  return SingleChildScrollView(
                    child: Column(
                      children: [
                        _WelcomeHeader(uid: uid, email: user?.email),
                        _AlertBanner(
                          readings: alertReadings,
                          siteById: siteById,
                        ),
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
                        const SizedBox(height: 8),
                        _TrendChartsSection(
                          sites: sites,
                          allReadings: readings,
                        ),
                        const Divider(height: 1),
                        if (filteredReadings.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'No readings match the current filter',
                              ),
                            ),
                          )
                        else
                          ListView.builder(
                            padding: const EdgeInsets.all(12),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
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
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.readings, required this.siteById});

  final List<Reading> readings;
  final Map<String, Site> siteById;

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red.shade700),
              const SizedBox(width: 8),
              Text(
                'Active Alerts (${readings.length})',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final reading in readings)
            _AlertBannerRow(reading: reading, site: siteById[reading.siteId]),
        ],
      ),
    );
  }
}

class _AlertBannerRow extends StatelessWidget {
  const _AlertBannerRow({required this.reading, required this.site});

  final Reading reading;
  final Site? site;

  @override
  Widget build(BuildContext context) {
    final siteName = site?.name ?? reading.siteId;
    final dangerLevel = site?.dangerLevel;
    final level = reading.manualLevel ?? reading.aiDetectedLevel;
    final levelText = level != null ? '${level.toStringAsFixed(1)}m' : '—';
    final dangerText = dangerLevel != null
        ? '${dangerLevel.toStringAsFixed(1)}m'
        : 'unknown';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '⚠️ $siteName: $levelText recorded, exceeds danger level of '
        '$dangerText — ${_timeAgo(reading.timestamp)}',
        style: TextStyle(color: Colors.red.shade900),
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

class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({required this.uid, required this.email});

  final String? uid;
  final String? email;

  @override
  Widget build(BuildContext context) {
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final userData = snapshot.data?.data() as Map<String, dynamic>?;
        final userName = userData?['name'] ?? email ?? 'Analyst';

        return Padding(
          padding: const EdgeInsets.only(left: 12, right: 12, top: 12),
          child: Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.blue.shade50,
                    child: Icon(Icons.analytics, size: 22, color: Colors.blue.shade600),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome, $userName!',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Analyst Panel — monitor flood indicators and trend reports',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
            if (reading.isSubmerged) ...[
              const SizedBox(height: 4),
              const Row(
                children: [
                  Icon(Icons.warning, color: Colors.red, size: 14),
                  SizedBox(width: 4),
                  Text(
                    'Gauge Submerged!',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
            if (reading.isBlurryOrDark) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.image, color: Colors.orange.shade700, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    'Quality Issue',
                    style: TextStyle(
                      color: Colors.orange.shade700,
                      fontWeight: FontWeight.w500,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
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
                if (reading.isSubmerged)
                  const _DetailRow(
                    label: 'Submerged Gauge',
                    value: '⚠️ YES - Water level is at/above max gauge height!',
                  ),
                if (reading.isBlurryOrDark)
                  const _DetailRow(
                    label: 'Quality Issues',
                    value: '⚠️ YES - Image flagged as blurry or too dark',
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

/// New charts section: a per-site trend line (with a danger-level reference
/// line) plus an all-sites reading-status bar chart. Purely additive — the
/// stat cards, filters, and reading list above/below are untouched.
class _TrendChartsSection extends StatefulWidget {
  const _TrendChartsSection({required this.sites, required this.allReadings});

  final List<Site> sites;
  final List<Reading> allReadings;

  @override
  State<_TrendChartsSection> createState() => _TrendChartsSectionState();
}

class _TrendChartsSectionState extends State<_TrendChartsSection> {
  String? _selectedSiteId;

  @override
  Widget build(BuildContext context) {
    if (widget.sites.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text('No sites available yet.'),
      );
    }

    // Default to the first site until the analyst picks one explicitly.
    final selectedSiteId = _selectedSiteId ?? widget.sites.first.siteId;
    final selectedSite = widget.sites.firstWhere(
      (s) => s.siteId == selectedSiteId,
      orElse: () => widget.sites.first,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Site',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          DropdownButton<String>(
            value: selectedSiteId,
            isExpanded: true,
            items: widget.sites
                .map(
                  (s) =>
                      DropdownMenuItem(value: s.siteId, child: Text(s.name)),
                )
                .toList(),
            onChanged: (value) => setState(() => _selectedSiteId = value),
          ),
          const SizedBox(height: 8),
          _SiteTrendLineChart(
            key: ValueKey('trend_$selectedSiteId'),
            siteId: selectedSiteId,
            site: selectedSite,
          ),
          const SizedBox(height: 16),
          _WeatherSection(
            key: ValueKey('weather_$selectedSiteId'),
            site: selectedSite,
          ),
          const SizedBox(height: 16),
          const Text(
            'Reading Status — all sites',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          _StatusBarChart(readings: widget.allReadings),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Line chart of one site's readings over the last 30 days (or all
/// available history if the site has less than that), with a dashed red
/// reference line at the site's danger level.
class _SiteTrendLineChart extends StatelessWidget {
  const _SiteTrendLineChart({super.key, required this.siteId, required this.site});

  final String siteId;
  final Site site;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      // Filtered by siteId only (no orderBy on a second field) so this
      // doesn't require a composite Firestore index — sorting/windowing by
      // timestamp happens client-side below, same convention the rest of
      // this screen already uses for status/site filtering.
      stream: FirebaseFirestore.instance
          .collection('readings')
          .where('siteId', isEqualTo: siteId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(
            height: 220,
            child: Center(child: Text('Failed to load trend: ${snapshot.error}')),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 220,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        final readings =
            docs
                .map(
                  (doc) =>
                      Reading.fromMap({...doc.data(), 'readingId': doc.id}),
                )
                .toList()
              ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

        final cutoff = DateTime.now().subtract(const Duration(days: 30));
        final spots = <FlSpot>[];
        for (final r in readings) {
          final level = r.manualLevel ?? r.aiDetectedLevel;
          if (level == null) continue;
          if (r.timestamp.isBefore(cutoff)) continue;
          spots.add(FlSpot(r.timestamp.millisecondsSinceEpoch.toDouble(), level));
        }

        if (spots.length < 2) {
          return const SizedBox(
            height: 220,
            child: Center(child: Text('Not enough data yet')),
          );
        }

        final minX = spots.first.x;
        final maxX = spots.last.x;
        final dataValues = spots.map((s) => s.y).toList();
        final lowest = [...dataValues, site.dangerLevel].reduce(
          (a, b) => a < b ? a : b,
        );
        final highest = [...dataValues, site.dangerLevel].reduce(
          (a, b) => a > b ? a : b,
        );
        final xRange = maxX - minX;
        final xInterval = xRange > 0 ? xRange / 4 : 1.0;

        return SizedBox(
          height: 220,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: lowest - 0.5,
              maxY: highest + 0.5,
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(show: true),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 36),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: xInterval,
                    getTitlesWidget: (value, meta) {
                      final date = DateTime.fromMillisecondsSinceEpoch(
                        value.toInt(),
                      );
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _formatShortDate(date),
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: Colors.blue,
                  barWidth: 2,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(
                    show: true,
                    color: Colors.blue.withValues(alpha: 0.1),
                  ),
                ),
              ],
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(
                    y: site.dangerLevel,
                    color: Colors.red,
                    strokeWidth: 2,
                    dashArray: const [8, 4],
                    label: HorizontalLineLabel(
                      show: true,
                      alignment: Alignment.topRight,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      labelResolver: (_) => 'Danger: ${site.dangerLevel}m',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shows the most recent OpenWeatherMap reading recorded for the selected
/// site (from the `weather_data` collection), with a manual refresh button
/// that fetches a fresh reading on demand via [WeatherService].
class _WeatherSection extends StatefulWidget {
  const _WeatherSection({super.key, required this.site});

  final Site site;

  @override
  State<_WeatherSection> createState() => _WeatherSectionState();
}

class _WeatherSectionState extends State<_WeatherSection> {
  final _weatherService = WeatherService();
  bool _isRefreshing = false;

  Future<void> _refresh() async {
    setState(() => _isRefreshing = true);
    await _weatherService.recordWeatherForSite(
      widget.site.siteId,
      widget.site.latitude,
      widget.site.longitude,
    );
    if (!mounted) return;
    setState(() => _isRefreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          // Equality filter only (no orderBy on a second field), same
          // convention used elsewhere in this app to avoid requiring a
          // composite Firestore index — sorted client-side below to find
          // the most recent entry.
          stream: FirebaseFirestore.instance
              .collection('weather_data')
              .where('siteId', isEqualTo: widget.site.siteId)
              .snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? [];
            final readings =
                docs.map((doc) => WeatherReading.fromMap(doc.data())).toList()
                  ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
            final latest = readings.isNotEmpty ? readings.first : null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Weather',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    _isRefreshing
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Fetch latest weather',
                            onPressed: _refresh,
                          ),
                  ],
                ),
                if (latest == null)
                  const Text('No weather data recorded yet.')
                else ...[
                  Text(
                    'Rainfall: ${latest.rainfall1h.toStringAsFixed(1)} mm '
                    '(1h) / ${latest.rainfall3h.toStringAsFixed(1)} mm (3h)',
                  ),
                  Text('Temperature: ${latest.temperature.toStringAsFixed(1)}°C'),
                  Text('Humidity: ${latest.humidity.toStringAsFixed(0)}%'),
                  Text('Conditions: ${latest.weatherDescription}'),
                  const SizedBox(height: 4),
                  Text(
                    'As of ${_formatTimestamp(latest.timestamp)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Bar chart of reading counts by status across all sites — a quick
/// health-of-data-pipeline view. Fed from the same top-100 readings stream
/// that already powers the stat cards above, so it updates live too.
class _StatusBarChart extends StatelessWidget {
  const _StatusBarChart({required this.readings});

  final List<Reading> readings;

  @override
  Widget build(BuildContext context) {
    final approved = readings
        .where((r) => r.status.toLowerCase() == 'approved')
        .length;
    final pending = readings
        .where((r) => r.status.toLowerCase() == 'pending')
        .length;
    final rejected = readings
        .where((r) => r.status.toLowerCase() == 'rejected')
        .length;
    final maxCount = [
      approved,
      pending,
      rejected,
    ].reduce((a, b) => a > b ? a : b);
    const labels = ['Approved', 'Pending', 'Rejected'];

    return SizedBox(
      height: 160,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: (maxCount == 0 ? 1 : maxCount).toDouble() * 1.2,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 28),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= labels.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      labels[index],
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            BarChartGroupData(
              x: 0,
              barRods: [
                BarChartRodData(
                  toY: approved.toDouble(),
                  color: Colors.green,
                  width: 24,
                ),
              ],
            ),
            BarChartGroupData(
              x: 1,
              barRods: [
                BarChartRodData(
                  toY: pending.toDouble(),
                  color: Colors.orange,
                  width: 24,
                ),
              ],
            ),
            BarChartGroupData(
              x: 2,
              barRods: [
                BarChartRodData(
                  toY: rejected.toDouble(),
                  color: Colors.red,
                  width: 24,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
