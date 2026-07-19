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

// ---- Design tokens for this screen's redesign ----
const _darkBlue = Color(0xFF1A3A57);
const _pageBackground = Color(0xFFF8F9FA);
const _cardRadius = 12.0;
const _sectionLabelStyle = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w700,
  color: AppColors.onSurfaceVariant,
  letterSpacing: 0.3,
);

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

// ---- Demo-only hardcoded river connections, used to derive the cascade
// banner / release recommendations / river network cascade notes below.
// Deliberately client-side only (no new Firestore collection/query) and
// matched by case-insensitive substring against Site.name rather than
// exact equality, since seeded/demo site names don't always match these
// short keys exactly (e.g. a seeded KRS site named "Krishna Raja Sagara
// (KRS) Dam"). ----
const List<({String upstreamKey, String? downstreamKey})>
_demoReleaseChain = [
  (upstreamKey: 'krishna raja sagara', downstreamKey: 'mettur dam'),
  (upstreamKey: 'mettur dam', downstreamKey: 'test site'),
  (upstreamKey: 'test site', downstreamKey: null), // river mouth
];

String? _demoDownstreamKeyFor(String siteName) {
  final lower = siteName.toLowerCase();
  for (final link in _demoReleaseChain) {
    if (lower.contains(link.upstreamKey)) return link.downstreamKey;
  }
  return null;
}

Site? _findSiteByNameKey(List<Site> sites, String key) {
  for (final s in sites) {
    if (s.name.toLowerCase().contains(key)) return s;
  }
  return null;
}

/// Latest recorded level per site, keyed by siteId. Relies on [allReadings]
/// already being newest-first (the dashboard's readings query orders by
/// timestamp descending), so the first match per site is its latest usable
/// reading.
Map<String, double> _latestLevelBySite(List<Reading> allReadings) {
  final result = <String, double>{};
  for (final r in allReadings) {
    if (result.containsKey(r.siteId)) continue;
    final level = r.manualLevel ?? r.aiDetectedLevel;
    if (level == null) continue;
    result[r.siteId] = level;
  }
  return result;
}

enum _Severity { red, orange, yellow, normal }

// Thresholds match the language already used in this app's generated
// reading summaries: 80% of danger = "approaching" (yellow), 95% = "near"
// (orange), 100%+ = at/above danger (red).
_Severity _severityFor(double level, double dangerLevel) {
  final ratio = dangerLevel > 0 ? level / dangerLevel : 0.0;
  if (ratio >= 1.0) return _Severity.red;
  if (ratio >= 0.95) return _Severity.orange;
  if (ratio >= 0.80) return _Severity.yellow;
  return _Severity.normal;
}

Color _severityColor(_Severity s) {
  switch (s) {
    case _Severity.red:
      return Colors.red;
    case _Severity.orange:
      return Colors.orange;
    case _Severity.yellow:
      return Colors.amber.shade700;
    case _Severity.normal:
      return Colors.green;
  }
}

String _severityLabel(_Severity s) {
  switch (s) {
    case _Severity.red:
      return 'Red';
    case _Severity.orange:
      return 'Orange';
    case _Severity.yellow:
      return 'Yellow';
    case _Severity.normal:
      return 'Normal';
  }
}

/// A site currently above its own danger level, paired with its
/// (demo-hardcoded) downstream site — feeds the cascade banner, the
/// release recommendation cards, and the river network cascade notes, so
/// the "which sites are risky right now" computation only happens once
/// per build.
class _CascadeLink {
  _CascadeLink({
    required this.site,
    required this.currentLevel,
    required this.downstreamSite,
    required this.downstreamLevel,
  });

  final Site site;
  final double currentLevel;
  final Site? downstreamSite;
  final double? downstreamLevel;

  bool get releaseSafe {
    // No downstream site at all (river mouth) — nothing to flood, so a
    // release is safe by default.
    if (downstreamSite == null || downstreamLevel == null) return true;
    return downstreamLevel! < downstreamSite!.dangerLevel;
  }
}

List<_CascadeLink> _computeCascadeLinks(
  List<Site> sites,
  Map<String, double> levelBySite,
) {
  final links = <_CascadeLink>[];
  for (final site in sites) {
    final level = levelBySite[site.siteId];
    if (level == null || level < site.dangerLevel) continue;

    final downstreamKey = _demoDownstreamKeyFor(site.name);
    Site? downstreamSite;
    double? downstreamLevel;
    if (downstreamKey != null) {
      downstreamSite = _findSiteByNameKey(sites, downstreamKey);
      if (downstreamSite != null) {
        downstreamLevel = levelBySite[downstreamSite.siteId];
      }
    }

    links.add(
      _CascadeLink(
        site: site,
        currentLevel: level,
        downstreamSite: downstreamSite,
        downstreamLevel: downstreamLevel,
      ),
    );
  }
  return links;
}

class AnalystDashboardScreen extends StatefulWidget {
  const AnalystDashboardScreen({super.key});

  @override
  State<AnalystDashboardScreen> createState() => _AnalystDashboardScreenState();
}

class _AnalystDashboardScreenState extends State<AnalystDashboardScreen> {
  String _statusFilter = 'All';
  String? _siteFilterId;
  String? _selectedTrendSiteId;

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
                // Scaffold now lives here, one level deeper than before, so
                // the app bar's notification bell can reflect alertReadings
                // (the same already-computed list the alert banner already
                // used) — same queries throughout, just relocated.
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

                  final levelBySite = _latestLevelBySite(readings);
                  final cascadeLinks = _computeCascadeLinks(sites, levelBySite);

                  final trendSiteId = _selectedTrendSiteId ??
                      (sites.isNotEmpty ? sites.first.siteId : null);
                  final trendSite = sites.isEmpty
                      ? null
                      : sites.firstWhere(
                          (s) => s.siteId == trendSiteId,
                          orElse: () => sites.first,
                        );

                  // The whole body scrolls as one column: every section
                  // below is always visible (no tabs), matching the new
                  // top-to-bottom layout.
                  body = SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      children: [
                        _CascadeRiskBanner(links: cascadeLinks),
                        _AlertBanner(
                          readings: alertReadings,
                          siteById: siteById,
                        ),
                        _StatsRow(
                          readings: readings,
                          alertCount: alertReadings.length,
                        ),
                        _WarningDistributionSection(
                          sites: sites,
                          levelBySite: levelBySite,
                        ),
                        if (trendSite != null)
                          _WaterLevelTrendSection(
                            sites: sites,
                            selectedSite: trendSite,
                            onSiteChanged: (value) =>
                                setState(() => _selectedTrendSiteId = value),
                          ),
                        _ReleaseRecommendationsSection(links: cascadeLinks),
                        _RiverNetworkSection(
                          sites: sites,
                          levelBySite: levelBySite,
                          cascadeLinks: cascadeLinks,
                        ),
                        if (trendSite != null)
                          _WeatherSection(
                            key: ValueKey('weather_${trendSite.siteId}'),
                            site: trendSite,
                          ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Live Readings', style: _sectionLabelStyle),
                          ),
                        ),
                        _FilterRow(
                          statusFilter: _statusFilter,
                          siteFilterId: _siteFilterId,
                          sites: sites,
                          onStatusChanged: (value) =>
                              setState(() => _statusFilter = value),
                          onSiteChanged: (value) =>
                              setState(() => _siteFilterId = value),
                        ),
                        Container(
                          margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(_cardRadius),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              const _ReadingsTableHeader(),
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
                                  padding: const EdgeInsets.all(8),
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
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Scaffold(
                  backgroundColor: _pageBackground,
                  appBar: AppBar(
                    backgroundColor: _darkBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
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
                        Text(
                          l10n.appTitle,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const _LiveIndicator(),
                      ],
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
                );
              },
            );
          },
        );
      },
    );
  }
}

class _LiveIndicator extends StatelessWidget {
  const _LiveIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LivePulseDot(),
          SizedBox(width: 4),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePulseDot extends StatelessWidget {
  const _LivePulseDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: Colors.greenAccent,
        shape: BoxShape.circle,
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

/// Item 2 — "Cascade Risk Warning" banner: amber left border, yellow
/// background. Purely client-side (from the already-computed
/// [_CascadeLink] list — no new Firestore query), shown only when at
/// least one site above danger has a resolvable downstream site.
class _CascadeRiskBanner extends StatelessWidget {
  const _CascadeRiskBanner({required this.links});

  final List<_CascadeLink> links;

  @override
  Widget build(BuildContext context) {
    final withDownstream = links.where((l) => l.downstreamSite != null).toList();
    if (withDownstream.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border(left: BorderSide(color: Colors.amber.shade700, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.water, color: Colors.amber.shade900, size: 18),
              const SizedBox(width: 8),
              Text(
                'Cascade Risk Warning',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.amber.shade900,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final link in withDownstream)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${link.site.name} is above danger — '
                '${link.downstreamSite!.name} downstream may be affected.',
                style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
              ),
            ),
        ],
      ),
    );
  }
}

/// Item 3 — "Active Alerts" banner: red left border, pink background.
class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.readings, required this.siteById});

  final List<Reading> readings;
  final Map<String, Site> siteById;

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border(left: BorderSide(color: Colors.red.shade400, width: 4)),
      ),
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

/// Item 4 — 2x2 stats grid, each card with a colored top border matching
/// its severity.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.readings, required this.alertCount});

  final List<Reading> readings;
  final int alertCount;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // "Approved Today" combines the two filter predicates already used
    // individually elsewhere on this dashboard (today's date, approved
    // status) — no new query, just their intersection over the same
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
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.6,
        children: [
          _StatCard(
            label: 'Danger Sites',
            value: alertCount,
            color: Colors.red,
            icon: Icons.warning_amber_rounded,
          ),
          _StatCard(
            label: 'Approved Today',
            value: approvedTodayCount,
            color: Colors.green,
          ),
          _StatCard(
            label: 'Pending',
            value: pendingCount,
            color: Colors.orange,
          ),
          _StatCard(
            label: 'Total Readings',
            value: readings.length,
            color: Colors.blue,
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border(top: BorderSide(color: color, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
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
    );
  }
}

/// Reusable white "section card": section-label header + content, 12px
/// radius, used by items 5, 6, and 8 below.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _sectionLabelStyle),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Item 5 — "Warning Level Distribution": horizontal bars for how many
/// sites currently fall into each of the Red/Orange/Yellow/Normal
/// severity buckets, based on each site's latest recorded level vs its
/// own danger threshold.
class _WarningDistributionSection extends StatelessWidget {
  const _WarningDistributionSection({
    required this.sites,
    required this.levelBySite,
  });

  final List<Site> sites;
  final Map<String, double> levelBySite;

  @override
  Widget build(BuildContext context) {
    var red = 0, orange = 0, yellow = 0, normal = 0;
    for (final site in sites) {
      final level = levelBySite[site.siteId];
      if (level == null) continue;
      switch (_severityFor(level, site.dangerLevel)) {
        case _Severity.red:
          red++;
          break;
        case _Severity.orange:
          orange++;
          break;
        case _Severity.yellow:
          yellow++;
          break;
        case _Severity.normal:
          normal++;
          break;
      }
    }

    final entries = [
      (_severityLabel(_Severity.red), red, _severityColor(_Severity.red)),
      (_severityLabel(_Severity.orange), orange, _severityColor(_Severity.orange)),
      (_severityLabel(_Severity.yellow), yellow, _severityColor(_Severity.yellow)),
      (_severityLabel(_Severity.normal), normal, _severityColor(_Severity.normal)),
    ];
    final maxCount = entries
        .map((e) => e.$2)
        .fold<int>(0, (a, b) => a > b ? a : b);

    return _SectionCard(
      title: 'Warning Level Distribution',
      child: Column(
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      entry.$1,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        Container(
                          height: 18,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: maxCount == 0
                              ? 0.0
                              : (entry.$2 / maxCount).clamp(0.0, 1.0),
                          child: Container(
                            height: 18,
                            decoration: BoxDecoration(
                              color: entry.$3,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 24,
                    child: Text(
                      '${entry.$2}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Item 6 — "Water Level Trend": per-site line chart with a dashed danger
/// threshold line. The site dropdown's selection is lifted to the parent
/// state so the Weather card (item 9) further down the page can reuse the
/// same selected site.
class _WaterLevelTrendSection extends StatelessWidget {
  const _WaterLevelTrendSection({
    required this.sites,
    required this.selectedSite,
    required this.onSiteChanged,
  });

  final List<Site> sites;
  final Site selectedSite;
  final ValueChanged<String?> onSiteChanged;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Water Level Trend',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<String>(
            value: selectedSite.siteId,
            isExpanded: true,
            items: sites
                .map(
                  (s) => DropdownMenuItem(value: s.siteId, child: Text(s.name)),
                )
                .toList(),
            onChanged: onSiteChanged,
          ),
          const SizedBox(height: 8),
          _SiteTrendLineChart(
            key: ValueKey('trend_${selectedSite.siteId}'),
            siteId: selectedSite.siteId,
            site: selectedSite,
          ),
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
                  color: AppColors.primary,
                  barWidth: 2,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(
                    show: true,
                    color: AppColors.primary.withValues(alpha: 0.1),
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

/// Item 7 — "Coordinated Release Recommendations": for every site above
/// danger with a resolvable downstream site, a card flagging whether an
/// upstream release would be safe. Pure client-side computation (from the
/// already-computed [_CascadeLink] list) — this is a decision-support
/// aid, not an automated control, hence the disclaimer footer.
class _ReleaseRecommendationsSection extends StatelessWidget {
  const _ReleaseRecommendationsSection({required this.links});

  final List<_CascadeLink> links;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Coordinated Release Recommendations', style: _sectionLabelStyle),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final link in links) ...[
                  _ReleaseSafetyCard(link: link),
                  const SizedBox(width: 12),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Decision-support only — all release decisions must be made by '
            'authorized dam operators following CWC protocols. This system '
            'does not control any physical infrastructure.',
            style: TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseSafetyCard extends StatelessWidget {
  const _ReleaseSafetyCard({required this.link});

  final _CascadeLink link;

  @override
  Widget build(BuildContext context) {
    final safe = link.releaseSafe;
    final color = safe ? Colors.green : Colors.red;
    final downstreamSite = link.downstreamSite;
    final downstreamLevel = link.downstreamLevel;

    final String reason;
    if (downstreamSite == null || downstreamLevel == null) {
      reason = 'No downstream site — this is the river mouth. Release is safe.';
    } else if (downstreamLevel >= downstreamSite.dangerLevel) {
      reason = 'Downstream ${downstreamSite.name} is at '
          '${downstreamLevel.toStringAsFixed(1)}m — already above danger';
    } else {
      reason = 'Downstream is safe — current level '
          '${downstreamLevel.toStringAsFixed(1)}m below danger '
          '${downstreamSite.dangerLevel.toStringAsFixed(1)}m';
    }

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border(top: BorderSide(color: color, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              link.site.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              '${link.currentLevel.toStringAsFixed(1)}m vs danger '
              '${link.site.dangerLevel.toStringAsFixed(1)}m',
              style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                border: Border.all(color: color),
              ),
              child: Text(
                safe ? 'RELEASE SAFE' : 'DO NOT RELEASE',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(reason, style: const TextStyle(fontSize: 11, color: Color(0xFF1A1A1A))),
          ],
        ),
      ),
    );
  }
}

/// Item 8 — "River Network Status": every site as a row, colored left
/// border by severity, with a cascade-warning note for any site that also
/// shows up in [_CascadeLink] (i.e. above danger with a downstream site
/// on the same demo river chain).
class _RiverNetworkSection extends StatelessWidget {
  const _RiverNetworkSection({
    required this.sites,
    required this.levelBySite,
    required this.cascadeLinks,
  });

  final List<Site> sites;
  final Map<String, double> levelBySite;
  final List<_CascadeLink> cascadeLinks;

  @override
  Widget build(BuildContext context) {
    if (sites.isEmpty) {
      return const _SectionCard(
        title: 'River Network Status',
        child: Text('No sites available yet.'),
      );
    }

    final cascadeBySiteId = {for (final l in cascadeLinks) l.site.siteId: l};

    return _SectionCard(
      title: 'River Network Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final site in sites) ...[
            _RiverNetworkRow(
              site: site,
              level: levelBySite[site.siteId],
              cascadeLink: cascadeBySiteId[site.siteId],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _RiverNetworkRow extends StatelessWidget {
  const _RiverNetworkRow({
    required this.site,
    required this.level,
    required this.cascadeLink,
  });

  final Site site;
  final double? level;
  final _CascadeLink? cascadeLink;

  @override
  Widget build(BuildContext context) {
    final severity = level == null ? null : _severityFor(level!, site.dangerLevel);
    final color = severity == null ? Colors.grey : _severityColor(severity);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  site.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                level != null
                    ? '${level!.toStringAsFixed(1)}m / ${site.dangerLevel.toStringAsFixed(1)}m'
                    : 'No data',
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (cascadeLink != null) ...[
            const SizedBox(height: 4),
            Text(
              cascadeLink!.downstreamSite != null
                  ? 'Cascade warning — may affect downstream '
                      '${cascadeLink!.downstreamSite!.name}'
                  : 'Above danger — river mouth, no downstream site',
              style: TextStyle(
                fontSize: 11,
                color: Colors.amber.shade900,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Item 9 — Weather card: dark blue background, temperature, rainfall,
/// humidity for the same site currently selected in the Water Level Trend
/// section above. Shows the most recent OpenWeatherMap reading recorded
/// for that site (from the `weather_data` collection), with a manual
/// refresh button that fetches a fresh reading on demand via
/// [WeatherService]. Also auto-triggers one fetch when a site has no
/// weather data at all yet (same fallback capture_screen.dart's
/// _SiteWeatherCard already has) — without this, any site that was never
/// used in the field-capture flow would show "No weather data recorded
/// yet." indefinitely unless someone remembers to tap the refresh icon.
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
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _darkBlue,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
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
                      'Weather — ',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  Text(
                    widget.site.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  _isRefreshing
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white),
                          tooltip: 'Fetch latest weather',
                          onPressed: _refresh,
                        ),
                ],
              ),
              if (latest == null)
                const Text(
                  'No weather data recorded yet.',
                  style: TextStyle(color: Colors.white70),
                )
              else ...[
                Text(
                  'Rainfall: ${latest.rainfall1h.toStringAsFixed(1)} mm '
                  '(1h) / ${latest.rainfall3h.toStringAsFixed(1)} mm (3h)',
                  style: const TextStyle(color: Colors.white),
                ),
                Text(
                  'Temperature: ${latest.temperature.toStringAsFixed(1)}°C',
                  style: const TextStyle(color: Colors.white),
                ),
                Text(
                  'Humidity: ${latest.humidity.toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white),
                ),
                Text(
                  'Conditions: ${latest.weatherDescription}',
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  'As of ${_formatTimestamp(latest.timestamp)}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ReadingsTableHeader extends StatelessWidget {
  const _ReadingsTableHeader();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: AppColors.onSurfaceVariant,
    );
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('SITE', style: style)),
          Expanded(flex: 3, child: Text('TIME', style: style)),
          Expanded(flex: 2, child: Text('LEVEL', style: style)),
          Expanded(
            flex: 2,
            child: Text('STATUS', style: style, textAlign: TextAlign.right),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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

/// Item 10 — one row of the Live Readings table: site, time, level,
/// status columns.
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

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_cardRadius),
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
                      level != null ? '${level.toStringAsFixed(1)}m' : '—',
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
    // isAlert is already on the Reading itself (no new data) — a reading
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
                            : '—',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MetricCard(
                        label: 'Threshold',
                        value: site != null
                            ? '${site!.dangerLevel.toStringAsFixed(1)}m'
                            : '—',
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
  // to its localized display text — display-only.
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
