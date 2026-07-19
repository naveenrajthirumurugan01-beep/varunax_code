import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../models/weather_reading_model.dart';
import '../../services/auth_service.dart';
import '../../services/weather_service.dart';
import '../satellite_overlay_screen.dart';
import '../../utils/report_generator.dart';

const _statusOptions = ['All', 'Pending', 'Approved', 'Rejected'];

enum _DashboardTab { overview, detailed }

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
  _DashboardTab _activeTab = _DashboardTab.overview;

  final Set<String> _seenAlertIds = {};
  bool _alertsInitialized = false;

  Future<void> _logout(BuildContext context) async {
    await AuthService().signOut();
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  void _showDetail(
    BuildContext context,
    Reading reading,
    String siteName,
    Site? site,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => _ReadingDetailDialog(
        reading: reading,
        siteName: siteName,
        site: site,
      ),
    );
  }

  // Compares this snapshot of active alerts against the previous one
  // (tracked via _seenAlertIds) and pops up a dialog for any reading that
  // wasn't there before. The very first snapshot just establishes the
  // baseline â€” otherwise every pre-existing alert would trigger a popup the
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
            title: const Text('âš ï¸ Water Level Alert'),
            content: Text(
              'âš ï¸ Water Level Alert â€” $siteName has exceeded its danger '
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

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
          // composite Firestore index â€” sorted client-side below.
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
                // Scaffold now lives here, one level deeper than before, so
                // the app bar's notification bell can reflect alertReadings
                // (the same already-computed list the alert banner already
                // used) â€” same queries throughout, just relocated.
                final l10n = AppLocalizations.of(context)!;
                final Widget body;
                if (readingsSnapshot.hasError) {
                  body = Center(
                    child: Text(
                      'Failed to load readings: ${readingsSnapshot.error}',
                    ),
                  );
                } else if (readingsSnapshot.connectionState ==
                    ConnectionState.waiting) {
                  body = const Center(child: CircularProgressIndicator());
                } else {
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
                  // region â€” it's shrink-wrapped into this single scroll view
                  // so nothing gets clipped regardless of content height.
                  body = SingleChildScrollView(
                    child: Column(
                      children: [
                        _WelcomeHeader(uid: uid, email: user?.email),
                        // Alerts are safety-critical, so they stay visible
                        // regardless of which tab is active below.
                        _AlertBanner(
                          readings: alertReadings,
                          siteById: siteById,
                        ),
                        if (_activeTab == _DashboardTab.overview) ...[
                          _StatsRow(
                            readings: readings,
                            alertCount: alertReadings.length,
                          ),
                          const SizedBox(height: 8),
                          _TrendChartsSection(
                            sites: sites,
                            allReadings: readings,
                          ),
                        ] else ...[
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
                                  site: siteById[reading.siteId],
                                  onTap: () => _showDetail(
                                    context,
                                    reading,
                                    siteName,
                                    siteById[reading.siteId],
                                  ),
                                );
                              },
                            ),
                        ],
                      ],
                    ),
                  );
                }

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
                    title: Text(
                      l10n.appTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    actions: [
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: _NotificationBell(
                          hasAlerts: alertReadings.isNotEmpty,
                        ),
                      ),
                    ],
                  ),
                  body: body,
                  // Replaces the old top SegmentedButton â€” same _activeTab
                  // state, same setState call, just triggered from a bottom
                  // nav bar per the design instead of a top toggle.
                  bottomNavigationBar: BottomNavigationBar(
                    currentIndex: _activeTab == _DashboardTab.overview
                        ? 0
                        : 1,
                    onTap: (index) => setState(() {
                      _activeTab = index == 0
                          ? _DashboardTab.overview
                          : _DashboardTab.detailed;
                    }),
                    items: [
                      BottomNavigationBarItem(
                        icon: const Icon(Icons.home),
                        label: l10n.home,
                      ),
                      BottomNavigationBarItem(
                        icon: const Icon(Icons.history),
                        label: l10n.history,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Purely visual 24h/7d toggle â€” has no wiring to the chart below it, which
/// always shows its existing fixed last-30-days window. Local widget state
/// only, so tapping a pill just changes which one looks selected.
class _RangeToggle extends StatefulWidget {
  const _RangeToggle();

  @override
  State<_RangeToggle> createState() => _RangeToggleState();
}

class _RangeToggleState extends State<_RangeToggle> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _rangePill('24h', 0),
          _rangePill('7d', 1),
        ],
      ),
    );
  }

  Widget _rangePill(String label, int index) {
    final selected = _selected == index;
    return InkWell(
      onTap: () => setState(() => _selected = index),
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.onPrimary : AppColors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.hasAlerts});

  final bool hasAlerts;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.notifications_none),
        if (hasAlerts)
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
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
    final levelText = level != null ? '${level.toStringAsFixed(1)}m' : 'â€”';
    final dangerText = dangerLevel != null
        ? '${dangerLevel.toStringAsFixed(1)}m'
        : 'unknown';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        'âš ï¸ $siteName: $levelText recorded, exceeds danger level of '
        '$dangerText â€” ${_timeAgo(reading.timestamp)}',
        style: TextStyle(color: Colors.red.shade900),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.readings, required this.alertCount});

  final List<Reading> readings;
  final int alertCount;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // "Approved Today" combines the two filter predicates already used
    // individually elsewhere on this dashboard (today's date, approved
    // status) â€” no new query, just their intersection over the same
    // already-fetched readings list.
    final approvedTodayCount = readings
        .where(
          (r) =>
              r.status.toLowerCase() == 'approved' &&
              r.timestamp.year == now.year &&
              r.timestamp.month == now.month &&
              r.timestamp.day == now.day,
        )
        .length;
    final pendingCount = readings
        .where((r) => r.status.toLowerCase() == 'pending')
        .length;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.6,
        children: [
          _StatCard(
            label: 'Total Readings',
            value: readings.length,
            color: Colors.blue,
          ),
          _StatCard(
            label: 'Danger Level',
            value: alertCount,
            color: AppColors.error,
            icon: Icons.warning_amber_rounded,
          ),
          _StatCard(
            label: 'Pending Review',
            value: pendingCount,
            color: Colors.orange,
          ),
          _StatCard(
            label: 'Approved Today',
            value: approvedTodayCount,
            color: Colors.green,
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
    this.icon,
  });

  final String label;
  final int value;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 4),
                ],
                Text(
                  '$value',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Status',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final option in _statusOptions) ...[
                  _FilterPill(
                    label: option,
                    selected: statusFilter == option,
                    onTap: () => onStatusChanged(option),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Site',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterPill(
                  label: 'All sites',
                  selected: siteFilterId == null,
                  onTap: () => onSiteChanged(null),
                ),
                const SizedBox(width: 8),
                for (final site in sites) ...[
                  _FilterPill(
                    label: site.name,
                    selected: siteFilterId == site.siteId,
                    onTap: () => onSiteChanged(site.siteId),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({
    required this.reading,
    required this.siteName,
    required this.site,
    required this.onTap,
  });

  final Reading reading;
  final String siteName;
  final Site? site;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(reading.status);
    final level = reading.manualLevel ?? reading.aiDetectedLevel;
    final siteIdText = site?.siteCode ?? siteName;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      siteIdText,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      _formatTimestamp(reading.timestamp),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      level != null ? '${level.toStringAsFixed(1)}m' : 'â€”',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(
                            AppSpacing.radiusPill,
                          ),
                          border: Border.all(color: color),
                        ),
                        child: Text(
                          reading.status,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
              if (reading.isAlert || reading.isSubmerged) ...[
                const SizedBox(height: 6),
                InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => SatelliteOverlayScreen(siteId: reading.siteId),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.purple.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.satellite_alt, color: Colors.purple.shade700, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '⚠️ Ground risk high. Tap to view Satellite Radar Telemetry.',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.purple.shade800,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: Colors.purple.shade700, size: 14),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadingDetailDialog extends StatelessWidget {
  const _ReadingDetailDialog({
    required this.reading,
    required this.siteName,
    required this.site,
  });

  final Reading reading;
  final String siteName;
  final Site? site;

  @override
  Widget build(BuildContext context) {
    // isAlert is already on the Reading itself (no new data) â€” a reading
    // that triggered a danger-level alert is called out as "Critical" here
    // rather than showing its ordinary pending/approved/rejected status.
    final isCritical = reading.isAlert;
    final statusLabel = isCritical ? 'Critical' : reading.status;
    final color = isCritical ? AppColors.error : _statusColor(reading.status);
    final level = reading.manualLevel ?? reading.aiDetectedLevel;
    final siteIdText = site?.siteCode ?? siteName;

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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        siteIdText,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(
                          AppSpacing.radiusPill,
                        ),
                        border: Border.all(color: color),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (reading.photoUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusStandard,
                    ),
                    child: Stack(
                      children: [
                        Image.network(
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
                              child: Center(
                                child: CircularProgressIndicator(),
                              ),
                            );
                          },
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(
                                AppSpacing.radiusPill,
                              ),
                            ),
                            child: Text(
                              _formatTimestamp(reading.timestamp),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox(
                    height: 80,
                    child: Center(child: Text('Photo not yet uploaded')),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        label: 'Recorded Level',
                        value: level != null
                            ? '${level.toStringAsFixed(1)}m'
                            : 'â€”',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MetricCard(
                        label: 'Threshold',
                        value: site != null
                            ? '${site!.dangerLevel.toStringAsFixed(1)}m'
                            : 'â€”',
                      ),
                    ),
                  ],
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
                if (reading.phLevel != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                          width: 120,
                          child: Text(
                            'pH',
                            style: TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Row(
                            children: [
                              Text(reading.phLevel!.toStringAsFixed(1)),
                              if (reading.waterQualityStatus != null) ...[
                                const SizedBox(width: 8),
                                _WaterQualityBadge(
                                  status: reading.waterQualityStatus!,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (reading.isSubmerged)
                  const _DetailRow(
                    label: 'Submerged Gauge',
                    value: 'YES - Water level is at/above max gauge height!',
                  ),
                if (reading.isBlurryOrDark)
                  const _DetailRow(
                    label: 'Quality Issues',
                    value: 'YES - Image flagged as blurry or too dark',
                  ),
                if (reading.supervisorNote != null &&
                    reading.supervisorNote!.isNotEmpty)
                  _DetailRow(
                    label: 'Supervisor note',
                    value: reading.supervisorNote!,
                  ),
                if (site != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Summary',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(generateReadingSummary(reading, site!, null)),
                ],
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

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
      ),
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.onSurface,
            ),
          ),
        ],
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
                color: AppColors.onSurfaceVariant,
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

/// Small colored pill showing a reading's water-quality classification
/// (from PhDetectionService.classifyWaterQuality, stored on the reading as
/// Reading.waterQualityStatus) alongside its pH value.
class _WaterQualityBadge extends StatelessWidget {
  const _WaterQualityBadge({required this.status});

  final String status;

  Color get _color {
    switch (status) {
      case 'Safe':
        return Colors.green;
      case 'Caution':
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  // Maps the underlying status data value ('Safe'/'Caution'/'Unsafe', also
  // used for the color above and stored as-is on Reading.waterQualityStatus)
  // to its localized display text â€” display-only.
  String _localizedStatus(AppLocalizations l10n) {
    switch (status) {
      case 'Safe':
        return l10n.safe;
      case 'Caution':
        return l10n.caution;
      default:
        return l10n.unsafe;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: color),
      ),
      child: Text(
        _localizedStatus(l10n),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// New charts section: a per-site trend line (with a danger-level reference
/// line) plus an all-sites reading-status bar chart. Purely additive â€” the
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Water Level Trend',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      // Purely decorative â€” this dashboard has no existing
                      // time-range control to restyle, and the underlying
                      // chart always shows the last 30 days regardless of
                      // which pill looks selected. No new filtering logic.
                      const _RangeToggle(),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Site',
                    style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
                  ),
                  DropdownButton<String>(
                    value: selectedSiteId,
                    isExpanded: true,
                    items: widget.sites
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.siteId,
                            child: Text(s.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedSiteId = value),
                  ),
                  const SizedBox(height: 8),
                  _SiteTrendLineChart(
                    key: ValueKey('trend_$selectedSiteId'),
                    siteId: selectedSiteId,
                    site: selectedSite,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _WeatherSection(
            key: ValueKey('weather_$selectedSiteId'),
            site: selectedSite,
          ),
          const SizedBox(height: 16),
          const Text(
            'Water Level â€” all sites (latest reading)',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _AllSitesLevelChart(sites: widget.sites, allReadings: widget.allReadings),
          const SizedBox(height: 16),
          const Text(
            'Reading Status â€” all sites',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _StatusBarChart(readings: widget.allReadings),
          const SizedBox(height: 12),
          _StatusPieChart(readings: widget.allReadings),
          const SizedBox(height: 16),
          const Text(
            'Submission Activity â€” last 30 days',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _SubmissionHeatmap(readings: widget.allReadings),
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
      // doesn't require a composite Firestore index â€” sorting/windowing by
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
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (touchedSpots) => touchedSpots.map((spot) {
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      spot.x.toInt(),
                    );
                    return LineTooltipItem(
                      '${_formatShortDate(date)}\n'
                      '${spot.y.toStringAsFixed(2)}m',
                      const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    );
                  }).toList(),
                ),
              ),
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
/// that fetches a fresh reading on demand via [WeatherService]. Also
/// auto-triggers one fetch when a site has no weather data at all yet (same
/// fallback capture_screen.dart's _SiteWeatherCard already has) â€” without
/// this, any site that was never used in the field-capture flow would show
/// "No weather data recorded yet." indefinitely unless someone remembers to
/// tap the refresh icon.
class _WeatherSection extends StatefulWidget {
  const _WeatherSection({super.key, required this.site});

  final Site site;

  @override
  State<_WeatherSection> createState() => _WeatherSectionState();
}

class _WeatherSectionState extends State<_WeatherSection> {
  final _weatherService = WeatherService();
  bool _isRefreshing = false;
  bool _hasTriggeredFetch = false;

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
          // composite Firestore index â€” sorted client-side below to find
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

            if (latest == null &&
                !_hasTriggeredFetch &&
                !_isRefreshing &&
                snapshot.connectionState != ConnectionState.waiting) {
              _hasTriggeredFetch = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _refresh();
              });
            }

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
                          color: AppColors.onSurfaceVariant,
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
                  Text('Temperature: ${latest.temperature.toStringAsFixed(1)}Â°C'),
                  Text('Humidity: ${latest.humidity.toStringAsFixed(0)}%'),
                  Text('Conditions: ${latest.weatherDescription}'),
                  const SizedBox(height: 4),
                  Text(
                    'As of ${_formatTimestamp(latest.timestamp)}',
                    style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
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

/// Bar chart of reading counts by status across all sites â€” a quick
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

/// Pie chart showing the proportion of readings by status across all
/// sites â€” the same approved/pending/rejected counts as [_StatusBarChart],
/// just a different view of them.
class _StatusPieChart extends StatelessWidget {
  const _StatusPieChart({required this.readings});

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
    final total = approved + pending + rejected;

    if (total == 0) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('No readings yet')),
      );
    }

    const titleStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: Colors.white,
    );

    return Column(
      children: [
        SizedBox(
          height: 160,
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 32,
              sections: [
                if (approved > 0)
                  PieChartSectionData(
                    value: approved.toDouble(),
                    color: Colors.green,
                    title: '${(approved / total * 100).round()}%',
                    radius: 56,
                    titleStyle: titleStyle,
                  ),
                if (pending > 0)
                  PieChartSectionData(
                    value: pending.toDouble(),
                    color: Colors.orange,
                    title: '${(pending / total * 100).round()}%',
                    radius: 56,
                    titleStyle: titleStyle,
                  ),
                if (rejected > 0)
                  PieChartSectionData(
                    value: rejected.toDouble(),
                    color: Colors.red,
                    title: '${(rejected / total * 100).round()}%',
                    radius: 56,
                    titleStyle: titleStyle,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _PieLegendEntry(color: Colors.green, label: 'Approved', count: approved),
            _PieLegendEntry(color: Colors.orange, label: 'Pending', count: pending),
            _PieLegendEntry(color: Colors.red, label: 'Rejected', count: rejected),
          ],
        ),
      ],
    );
  }
}

class _PieLegendEntry extends StatelessWidget {
  const _PieLegendEntry({
    required this.color,
    required this.label,
    required this.count,
  });

  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text('$label ($count)', style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _SiteLevelEntry {
  const _SiteLevelEntry(this.site, this.level);

  final Site site;
  final double level;
}

/// Horizontal comparison of the latest recorded water level at every site,
/// so an analyst can see at a glance which sites are currently highest.
/// Colored per-site relative to that site's own dangerLevel: green well
/// below it, amber approaching it, red at or above it. Built with plain
/// widgets rather than fl_chart's BarChart, which in the version pinned by
/// this project (1.2.0) has no horizontal-orientation option.
class _AllSitesLevelChart extends StatelessWidget {
  const _AllSitesLevelChart({required this.sites, required this.allReadings});

  final List<Site> sites;
  final List<Reading> allReadings;

  @override
  Widget build(BuildContext context) {
    // allReadings is already newest-first (the same top-100 stream that
    // feeds the rest of this dashboard), so the first match per site here
    // is that site's latest reading with a usable level.
    final latestBySite = <String, Reading>{};
    for (final r in allReadings) {
      final level = r.manualLevel ?? r.aiDetectedLevel;
      if (level == null) continue;
      latestBySite.putIfAbsent(r.siteId, () => r);
    }

    final rows = <_SiteLevelEntry>[];
    for (final site in sites) {
      final reading = latestBySite[site.siteId];
      final level = reading?.manualLevel ?? reading?.aiDetectedLevel;
      if (level == null) continue;
      rows.add(_SiteLevelEntry(site, level));
    }
    rows.sort((a, b) => b.level.compareTo(a.level));

    if (rows.isEmpty) {
      return const SizedBox(
        height: 60,
        child: Center(child: Text('No recent level readings yet')),
      );
    }

    final maxScale = rows.fold<double>(
      0,
      (acc, r) => [acc, r.level, r.site.dangerLevel].reduce((a, b) => a > b ? a : b),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text(
                    row.site.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final ratio = row.site.dangerLevel > 0
                          ? row.level / row.site.dangerLevel
                          : 0.0;
                      final color = ratio >= 1.0
                          ? Colors.red
                          : ratio >= 0.7
                              ? Colors.amber.shade700
                              : Colors.green;
                      final widthFactor = maxScale > 0
                          ? (row.level / maxScale).clamp(0.0, 1.0)
                          : 0.0;
                      return Stack(
                        children: [
                          Container(
                            height: 18,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: widthFactor,
                            child: Container(
                              height: 18,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${row.level.toStringAsFixed(1)}m',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Calendar-heatmap-style view of reading submission activity over the last
/// 30 days â€” one square per day, darker for more readings that day. Fed
/// from the same top-100 readings stream as the rest of this dashboard, so
/// very high-volume days beyond that cap may under-count.
class _SubmissionHeatmap extends StatelessWidget {
  const _SubmissionHeatmap({required this.readings});

  final List<Reading> readings;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final startDay = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(days: 29));

    final countByDay = <DateTime, int>{
      for (var i = 0; i < 30; i++) startDay.add(Duration(days: i)): 0,
    };
    for (final r in readings) {
      final day = DateTime(
        r.timestamp.year,
        r.timestamp.month,
        r.timestamp.day,
      );
      if (countByDay.containsKey(day)) {
        countByDay[day] = countByDay[day]! + 1;
      }
    }

    final maxCount = countByDay.values.fold<int>(
      0,
      (a, b) => a > b ? a : b,
    );

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: countByDay.entries.map((entry) {
        final count = entry.value;
        final intensity = maxCount == 0 ? 0.0 : count / maxCount;
        final color = count == 0
            ? Colors.grey.shade200
            : Colors.blue.withValues(alpha: 0.25 + 0.75 * intensity);

        return Tooltip(
          message:
              '${_formatShortDate(entry.key)}: $count '
              'reading${count == 1 ? '' : 's'}',
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }).toList(),
    );
  }
}
