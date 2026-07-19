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
import '../../utils/cwc_export_action.dart';
import '../../utils/report_generator.dart';
import '../../widgets/cascade_risk_banner.dart';
import 'citizen_reports_screen.dart';

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

// Reading.warningLevel is a companion to isAlert, not a replacement —
// 'red' here is the exact same condition as isAlert == true. Returns null
// (caller falls back to the normal text color) when there's no warning.
Color? _warningLevelColor(String? warningLevel) {
  switch (warningLevel) {
    case 'yellow':
      return Colors.amber.shade800;
    case 'orange':
      return Colors.orange.shade800;
    case 'red':
      return Colors.red.shade700;
    default:
      return null;
  }
}

String _warningLevelEmoji(String warningLevel) {
  switch (warningLevel) {
    case 'yellow':
      return '🟡';
    case 'orange':
      return '🟠';
    case 'red':
    default:
      return '🔴';
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
  final _releaseRecommendationsSectionKey = GlobalKey();

  void _scrollToReleaseRecommendations() {
    final recommendationsContext =
        _releaseRecommendationsSectionKey.currentContext;
    if (recommendationsContext == null) return;
    Scrollable.ensureVisible(
      recommendationsContext,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

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
            title: const Text(
              '⚠️ Water Level Alert',
              style: TextStyle(color: Color(0xFF000000)),
            ),
            content: Text(
              '⚠️ Water Level Alert — $siteName has exceeded its danger '
              'threshold',
              style: const TextStyle(color: Color(0xFF1A1A1A)),
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
                      (doc) =>
                          Reading.fromMap({...doc.data(), 'readingId': doc.id}),
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
                final readingsCount = readingsSnapshot.data?.docs.length ?? 0;
                final Widget body;
                if (readingsSnapshot.hasError) {
                  body = Center(
                    child: Text(
                      'Failed to load readings: ${readingsSnapshot.error}',
                      style: const TextStyle(color: Color(0xFF1A1A1A)),
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
                  // region — it's shrink-wrapped into this single scroll view
                  // so nothing gets clipped regardless of content height.
                  body = SingleChildScrollView(
                    child: Column(
                      children: [
                        // Predicted downstream risk from CascadeAlertService
                        // — sits above everything else, including the
                        // welcome header, and renders nothing when there
                        // are no active warnings.
                        CascadeRiskBanner(
                          onViewRecommendations:
                              _scrollToReleaseRecommendations,
                        ),
                        _WelcomeHeader(uid: uid, email: user?.email),
                        // Alerts are safety-critical, so they stay visible
                        // regardless of which tab is active below.
                        _AlertBanner(
                          readings: alertReadings,
                          siteById: siteById,
                        ),
                        // Also safety-critical and also always visible
                        // regardless of tab — renders nothing when there
                        // are no active cascade warnings (same condition
                        // as CascadeRiskBanner above).
                        _ReleaseRecommendationsSection(
                          key: _releaseRecommendationsSectionKey,
                          sites: sites,
                          allReadings: readings,
                        ),
                        if (_activeTab == _DashboardTab.overview) ...[
                          _StatsRow(readings: readings),
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
                                  style: TextStyle(color: Color(0xFF1A1A1A)),
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
                      IconButton(
                        icon: const Icon(Icons.table_chart),
                        tooltip: readingsCount >= 5
                            ? 'Download Excel'
                            : 'Need at least 5 readings',
                        onPressed: readingsCount >= 5
                            ? () => exportCwcExcelReport(context)
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: _NotificationBell(
                          hasAlerts: alertReadings.isNotEmpty,
                        ),
                      ),
                    ],
                  ),
                  body: body,
                  // Replaces the old top SegmentedButton — same _activeTab
                  // state, same setState call, just triggered from a bottom
                  // nav bar per the design instead of a top toggle.
                  bottomNavigationBar: BottomNavigationBar(
                    currentIndex: _activeTab == _DashboardTab.overview ? 0 : 1,
                    // Citizen Reports (index 2) is a separate full-screen
                    // push, same as History already was on the supervisor
                    // home screen's bottom nav — it doesn't change
                    // _activeTab, so currentIndex above is untouched.
                    onTap: (index) {
                      if (index == 2) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const CitizenReportsScreen(),
                          ),
                        );
                        return;
                      }
                      setState(() {
                        _activeTab = index == 0
                            ? _DashboardTab.overview
                            : _DashboardTab.detailed;
                      });
                    },
                    items: [
                      BottomNavigationBarItem(
                        icon: const Icon(Icons.home),
                        label: l10n.home,
                      ),
                      BottomNavigationBarItem(
                        icon: const Icon(Icons.history),
                        label: l10n.history,
                      ),
                      const BottomNavigationBarItem(
                        icon: Icon(Icons.groups),
                        label: 'Citizen Reports',
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

/// Purely visual 24h/7d toggle — has no wiring to the chart below it, which
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
        children: [_rangePill('24h', 0), _rangePill('7d', 1)],
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

// Demo-only hardcoded river connections for the release-safety check
// below — deliberately independent of Site.downstreamSiteIds (which drives
// the separate cascade-warning feature and has a different real basin
// topology). Matched by case-insensitive substring against Site.name
// rather than exact equality, since the actual seeded/demo site names
// don't always match these short keys exactly (e.g. the seeded KRS site
// is named "Krishna Raja Sagara (KRS) Dam").
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

/// "Coordinated Release Recommendations" — for every site currently above
/// its own danger level, checks the (demo-hardcoded) downstream site on
/// the same river network and flags whether an upstream release would be
/// safe: RELEASE SAFE if the downstream site still has headroom, DO NOT
/// RELEASE if the downstream site is itself already above danger. Pure
/// client-side computation over the sites/readings this dashboard already
/// fetches — no new Firestore query. Renders nothing when no site is
/// currently above danger, same "renders nothing when empty" convention
/// used by CascadeRiskBanner.
class _ReleaseRecommendationsSection extends StatelessWidget {
  const _ReleaseRecommendationsSection({
    super.key,
    required this.sites,
    required this.allReadings,
  });

  final List<Site> sites;
  final List<Reading> allReadings;

  @override
  Widget build(BuildContext context) {
    final readingsBySite = <String, List<Reading>>{};
    for (final r in allReadings) {
      final level = r.manualLevel ?? r.aiDetectedLevel;
      if (level == null) continue;
      (readingsBySite[r.siteId] ??= []).add(r);
    }
    // allReadings is already newest-first (see the outer readings query's
    // orderBy('timestamp', descending: true)), so the first entry per site
    // is its latest reading.
    double? latestLevelFor(String siteId) {
      final siteReadings = readingsBySite[siteId];
      if (siteReadings == null || siteReadings.isEmpty) return null;
      return siteReadings.first.manualLevel ?? siteReadings.first.aiDetectedLevel;
    }

    final cards = <Widget>[];
    for (final site in sites) {
      final level = latestLevelFor(site.siteId);
      if (level == null || level < site.dangerLevel) continue;

      final downstreamKey = _demoDownstreamKeyFor(site.name);
      Site? downstreamSite;
      double? downstreamLevel;
      if (downstreamKey != null) {
        downstreamSite = _findSiteByNameKey(sites, downstreamKey);
        if (downstreamSite != null) {
          downstreamLevel = latestLevelFor(downstreamSite.siteId);
        }
      }

      cards.add(
        _ReleaseSafetyCard(
          key: ValueKey(site.siteId),
          site: site,
          currentLevel: level,
          downstreamSite: downstreamSite,
          downstreamLevel: downstreamLevel,
        ),
      );
    }

    if (cards.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Coordinated Release Recommendations',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final card in cards) ...[
                  card,
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
  const _ReleaseSafetyCard({
    super.key,
    required this.site,
    required this.currentLevel,
    required this.downstreamSite,
    required this.downstreamLevel,
  });

  final Site site;
  final double currentLevel;
  final Site? downstreamSite;
  final double? downstreamLevel;

  bool get _releaseSafe {
    // No downstream site at all (river mouth) — nothing to flood, so a
    // release is safe by default.
    if (downstreamSite == null || downstreamLevel == null) return true;
    return downstreamLevel! < downstreamSite!.dangerLevel;
  }

  String get _reason {
    if (downstreamSite == null || downstreamLevel == null) {
      return 'No downstream site — this is the river mouth. Release is safe.';
    }
    if (downstreamLevel! >= downstreamSite!.dangerLevel) {
      return 'Downstream ${downstreamSite!.name} is at '
          '${downstreamLevel!.toStringAsFixed(1)}m — already above danger';
    }
    return 'Downstream is safe — current level '
        '${downstreamLevel!.toStringAsFixed(1)}m below danger '
        '${downstreamSite!.dangerLevel.toStringAsFixed(1)}m';
  }

  @override
  Widget build(BuildContext context) {
    final safe = _releaseSafe;
    final color = safe ? Colors.green : Colors.red;

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        border: Border(left: BorderSide(color: color, width: 4)),
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
              site.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${currentLevel.toStringAsFixed(1)}m vs danger '
              '${site.dangerLevel.toStringAsFixed(1)}m',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
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
            Text(
              _reason,
              style: const TextStyle(fontSize: 11, color: Color(0xFF1A1A1A)),
            ),
          ],
        ),
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
          _WarningBreakdownCard(readings: readings),
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
  });

  final String label;
  final int value;
  final Color color;

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
              style: const TextStyle(fontSize: 12, color: Color(0xFF1A1A1A)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Replaces the old single-number "Danger Level" stat card — breaks the
/// count down by 3-level warning (red/orange/yellow) among readings from
/// the last 24 hours, using the same already-fetched readings list rather
/// than a new query. Reading.warningLevel is a companion to isAlert, not a
/// replacement, so 'red' here corresponds exactly to isAlert == true.
class _WarningBreakdownCard extends StatelessWidget {
  const _WarningBreakdownCard({required this.readings});

  final List<Reading> readings;

  @override
  Widget build(BuildContext context) {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final recent = readings.where((r) => r.timestamp.isAfter(cutoff));
    final redCount = recent.where((r) => r.warningLevel == 'red').length;
    final orangeCount = recent.where((r) => r.warningLevel == 'orange').length;
    final yellowCount = recent.where((r) => r.warningLevel == 'yellow').length;

    return Card(
      color: AppColors.error.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.error,
                  size: 16,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Danger Level',
                  style: TextStyle(fontSize: 12, color: Color(0xFF1A1A1A)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _WarningCountChip(
                  emoji: '🔴',
                  count: redCount,
                  color: Colors.red,
                ),
                _WarningCountChip(
                  emoji: '🟠',
                  count: orangeCount,
                  color: Colors.orange,
                ),
                _WarningCountChip(
                  emoji: '🟡',
                  count: yellowCount,
                  color: Colors.amber.shade700,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WarningCountChip extends StatelessWidget {
  const _WarningCountChip({
    required this.emoji,
    required this.count,
    required this.color,
  });

  final String emoji;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 13)),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
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
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
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
                    child: Icon(
                      Icons.analytics,
                      size: 22,
                      color: Colors.blue.shade600,
                    ),
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
                            color: Color(0xFF000000),
                          ),
                        ),
                        const Text(
                          'Analyst Panel — monitor flood indicators and trend reports',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.onSurfaceVariant,
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
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A1A),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      _formatTimestamp(reading.timestamp),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      level != null ? '${level.toStringAsFixed(1)}m' : '—',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color:
                            _warningLevelColor(reading.warningLevel) ??
                            const Color(0xFF1A1A1A),
                      ),
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
              if (reading.warningLevel != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      _warningLevelEmoji(reading.warningLevel!),
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      reading.warningLevel!.toUpperCase(),
                      style: TextStyle(
                        color: _warningLevelColor(reading.warningLevel),
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
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
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: const Color(0xFF000000),
                        ),
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
                              child: Center(child: CircularProgressIndicator()),
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
                    child: Center(
                      child: Text(
                        'Photo not yet uploaded',
                        style: TextStyle(color: Color(0xFF1A1A1A)),
                      ),
                    ),
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
                              Text(
                                reading.phLevel!.toStringAsFixed(1),
                                style: const TextStyle(
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
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
                  Text(
                    generateReadingSummary(reading, site!, null),
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
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
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFF1A1A1A)),
            ),
          ),
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
        child: Text(
          'No sites available yet.',
          style: TextStyle(color: Color(0xFF1A1A1A)),
        ),
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
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF000000),
                              ),
                        ),
                      ),
                      // Purely decorative — this dashboard has no existing
                      // time-range control to restyle, and the underlying
                      // chart always shows the last 30 days regardless of
                      // which pill looks selected. No new filtering logic.
                      const _RangeToggle(),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Site',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  DropdownButton<String>(
                    value: selectedSiteId,
                    isExpanded: true,
                    items: widget.sites
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.siteId,
                            child: Text(
                              s.name,
                              style: const TextStyle(color: Color(0xFF1A1A1A)),
                            ),
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
          _RainfallVsLevelChart(
            key: ValueKey('rainfall_$selectedSiteId'),
            site: selectedSite,
            allReadings: widget.allReadings,
          ),
          const SizedBox(height: 16),
          _WeatherSection(
            key: ValueKey('weather_$selectedSiteId'),
            site: selectedSite,
          ),
          const SizedBox(height: 16),
          const Text(
            'State-wise Overview',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _StateWiseOverviewSection(
            sites: widget.sites,
            allReadings: widget.allReadings,
          ),
          const SizedBox(height: 16),
          const Text(
            'Water Level — all sites (latest reading)',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _AllSitesLevelChart(
            sites: widget.sites,
            allReadings: widget.allReadings,
          ),
          const SizedBox(height: 16),
          const Text(
            'Reading Status — all sites',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _StatusBarChart(readings: widget.allReadings),
          const SizedBox(height: 12),
          _StatusPieChart(readings: widget.allReadings),
          const SizedBox(height: 16),
          const Text(
            'Submission Activity — last 30 days',
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
  const _SiteTrendLineChart({
    super.key,
    required this.siteId,
    required this.site,
  });

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
            child: Center(
              child: Text(
                'Failed to load trend: ${snapshot.error}',
                style: const TextStyle(color: Color(0xFF1A1A1A)),
              ),
            ),
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
          spots.add(
            FlSpot(r.timestamp.millisecondsSinceEpoch.toDouble(), level),
          );
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
        final lowest = [
          ...dataValues,
          site.dangerLevel,
        ].reduce((a, b) => a < b ? a : b);
        final highest = [
          ...dataValues,
          site.dangerLevel,
        ].reduce((a, b) => a > b ? a : b);
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

/// Feature 4 — dual-axis chart comparing the selected site's water level
/// trend (left axis, meters) against its rainfall history (right axis,
/// mm) over the last 24 hours. Level data is filtered client-side from
/// the already-fetched [allReadings] (no new query, per spec); rainfall
/// is the one new StreamBuilder this feature is explicitly allowed to add
/// (weather_data, an existing collection already written by
/// WeatherService).
///
/// fl_chart has no native dual-axis support, so the rainfall series is
/// linearly remapped onto the level axis's Y-range purely for plotting;
/// the right-axis tick labels reverse that mapping back to real mm
/// values so they still read correctly.
class _RainfallVsLevelChart extends StatelessWidget {
  const _RainfallVsLevelChart({
    super.key,
    required this.site,
    required this.allReadings,
  });

  final Site site;
  final List<Reading> allReadings;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rainfall vs Water Level — ${site.name}',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: const Color(0xFF000000),
              ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              // The only new Firestore query added for this feature — see
              // the class doc above.
              stream: FirebaseFirestore.instance
                  .collection('weather_data')
                  .where('siteId', isEqualTo: site.siteId)
                  .orderBy('timestamp', descending: true)
                  .limit(24)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return SizedBox(
                    height: 200,
                    child: Center(
                      child: Text(
                        'Failed to load rainfall data: ${snapshot.error}',
                        style: const TextStyle(color: Color(0xFF1A1A1A)),
                      ),
                    ),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 200,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final cutoff = DateTime.now().subtract(
                  const Duration(hours: 24),
                );

                final weatherReadings =
                    (snapshot.data?.docs ?? [])
                        .map((doc) => WeatherReading.fromMap(doc.data()))
                        .where((w) => w.timestamp.isAfter(cutoff))
                        .toList()
                      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

                final levelReadings =
                    allReadings
                        .where((r) => r.siteId == site.siteId)
                        .where((r) => r.timestamp.isAfter(cutoff))
                        .where(
                          (r) => (r.manualLevel ?? r.aiDetectedLevel) != null,
                        )
                        .toList()
                      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

                if (levelReadings.length < 2 || weatherReadings.length < 2) {
                  return const SizedBox(
                    height: 120,
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Insufficient data to show correlation — submit '
                          'more readings to enable this chart',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF1A1A1A)),
                        ),
                      ),
                    ),
                  );
                }

                final levelSpots = [
                  for (final r in levelReadings)
                    FlSpot(
                      r.timestamp.millisecondsSinceEpoch.toDouble(),
                      (r.manualLevel ?? r.aiDetectedLevel)!,
                    ),
                ];
                final rainfallSpots = [
                  for (final w in weatherReadings)
                    FlSpot(
                      w.timestamp.millisecondsSinceEpoch.toDouble(),
                      w.rainfall1h,
                    ),
                ];

                final levelValues = levelSpots.map((s) => s.y).toList();
                final minLevel = [
                  ...levelValues,
                  site.dangerLevel,
                ].reduce((a, b) => a < b ? a : b);
                final maxLevel = [
                  ...levelValues,
                  site.dangerLevel,
                ].reduce((a, b) => a > b ? a : b);
                final levelLow = minLevel - 0.5;
                final levelHigh = maxLevel + 0.5;

                final rainfallValues = rainfallSpots.map((s) => s.y).toList();
                final minRain = rainfallValues.reduce((a, b) => a < b ? a : b);
                final maxRain = rainfallValues.reduce((a, b) => a > b ? a : b);
                // Guards against a divide-by-zero below when rainfall is
                // completely flat across the whole window.
                final rainRange = (maxRain - minRain) == 0
                    ? 1.0
                    : (maxRain - minRain);

                double rainToLevelScale(double rainMm) {
                  return levelLow +
                      (rainMm - minRain) / rainRange * (levelHigh - levelLow);
                }

                double levelToRainScale(double levelValue) {
                  return minRain +
                      (levelValue - levelLow) /
                          (levelHigh - levelLow) *
                          rainRange;
                }

                final scaledRainfallSpots = [
                  for (final s in rainfallSpots)
                    FlSpot(s.x, rainToLevelScale(s.y)),
                ];

                final allX = [
                  ...levelSpots,
                  ...scaledRainfallSpots,
                ].map((s) => s.x).toList();
                final minX = allX.reduce((a, b) => a < b ? a : b);
                final maxX = allX.reduce((a, b) => a > b ? a : b);
                final xRange = maxX - minX;
                final xInterval = xRange > 0 ? xRange / 4 : 1.0;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 220,
                      child: LineChart(
                        LineChartData(
                          minX: minX,
                          maxX: maxX,
                          minY: levelLow,
                          maxY: levelHigh,
                          gridData: const FlGridData(show: true),
                          borderData: FlBorderData(show: true),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 36,
                                getTitlesWidget: (value, meta) => Text(
                                  '${value.toStringAsFixed(1)}m',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: Colors.blue,
                                  ),
                                ),
                              ),
                            ),
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 40,
                                getTitlesWidget: (value, meta) => Text(
                                  '${levelToRainScale(value).toStringAsFixed(0)}mm',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.teal.shade700,
                                  ),
                                ),
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 28,
                                interval: xInterval,
                                getTitlesWidget: (value, meta) {
                                  final date =
                                      DateTime.fromMillisecondsSinceEpoch(
                                        value.toInt(),
                                      );
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      '${date.hour.toString().padLeft(2, '0')}:00',
                                      style: const TextStyle(fontSize: 9),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          lineBarsData: [
                            LineChartBarData(
                              spots: levelSpots,
                              isCurved: false,
                              color: Colors.blue,
                              barWidth: 2,
                              dotData: const FlDotData(show: false),
                            ),
                            LineChartBarData(
                              spots: scaledRainfallSpots,
                              isCurved: false,
                              color: Colors.teal,
                              barWidth: 2,
                              dashArray: const [6, 4],
                              dotData: const FlDotData(show: false),
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
                                  labelResolver: (_) =>
                                      'Danger: ${site.dangerLevel}m',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(width: 16, height: 2, color: Colors.blue),
                        const SizedBox(width: 4),
                        const Text(
                          'Water Level',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < 3; i++) ...[
                              Container(
                                width: 4,
                                height: 2,
                                color: Colors.teal,
                              ),
                              const SizedBox(width: 2),
                            ],
                          ],
                        ),
                        const SizedBox(width: 2),
                        const Text(
                          'Rainfall',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the most recent OpenWeatherMap reading recorded for the selected
/// site (from the `weather_data` collection), with a manual refresh button
/// that fetches a fresh reading on demand via [WeatherService]. Also
/// auto-triggers one fetch when a site has no weather data at all yet (same
/// fallback capture_screen.dart's _SiteWeatherCard already has) — without
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
                  const Text(
                    'No weather data recorded yet.',
                    style: TextStyle(color: Color(0xFF1A1A1A)),
                  )
                else ...[
                  Text(
                    'Rainfall: ${latest.rainfall1h.toStringAsFixed(1)} mm '
                    '(1h) / ${latest.rainfall3h.toStringAsFixed(1)} mm (3h)',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  Text(
                    'Temperature: ${latest.temperature.toStringAsFixed(1)}°C',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  Text(
                    'Humidity: ${latest.humidity.toStringAsFixed(0)}%',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  Text(
                    'Conditions: ${latest.weatherDescription}',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'As of ${_formatTimestamp(latest.timestamp)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceVariant,
                    ),
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
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF1A1A1A),
                      ),
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
/// sites — the same approved/pending/rejected counts as [_StatusBarChart],
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
        child: Center(
          child: Text(
            'No readings yet',
            style: TextStyle(color: Color(0xFF1A1A1A)),
          ),
        ),
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
            _PieLegendEntry(
              color: Colors.green,
              label: 'Approved',
              count: approved,
            ),
            _PieLegendEntry(
              color: Colors.orange,
              label: 'Pending',
              count: pending,
            ),
            _PieLegendEntry(
              color: Colors.red,
              label: 'Rejected',
              count: rejected,
            ),
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
        Text(
          '$label ($count)',
          style: const TextStyle(fontSize: 11, color: Color(0xFF1A1A1A)),
        ),
      ],
    );
  }
}

// Feature 3 — derives the state abbreviation from a siteCode like
// "CWC-TN-001" (the same prefix convention cwc_excel_generator.dart's
// _stateInfo already relies on). Returns null for a siteCode that doesn't
// match the expected "CWC-<STATE>-<NNN>" shape.
String? _stateAbbrFromSiteCode(String siteCode) {
  final parts = siteCode.split('-');
  if (parts.length < 2) return null;
  return parts[1];
}

/// Feature 3 — three side-by-side cards (Tamil Nadu / Kerala / Karnataka),
/// each showing that state's site count, a red/orange/yellow/normal
/// breakdown (reusing Reading.calculateWarningLevel's exact thresholds —
/// no threshold logic duplicated here), and a border colored by that
/// state's single worst active warning level.
class _StateWiseOverviewSection extends StatelessWidget {
  const _StateWiseOverviewSection({
    required this.sites,
    required this.allReadings,
  });

  final List<Site> sites;
  final List<Reading> allReadings;

  static const _stateAbbrs = ['TN', 'KL', 'KA'];

  @override
  Widget build(BuildContext context) {
    final latestBySite = <String, Reading>{};
    for (final r in allReadings) {
      final level = r.manualLevel ?? r.aiDetectedLevel;
      if (level == null) continue;
      latestBySite.putIfAbsent(r.siteId, () => r);
    }

    return Row(
      children: [
        for (final abbr in _stateAbbrs) ...[
          Expanded(
            child: _StateCard(
              abbr: abbr,
              sites: sites
                  .where((s) => _stateAbbrFromSiteCode(s.siteCode) == abbr)
                  .toList(),
              latestBySite: latestBySite,
            ),
          ),
          if (abbr != _stateAbbrs.last) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.abbr,
    required this.sites,
    required this.latestBySite,
  });

  final String abbr;
  final List<Site> sites;
  final Map<String, Reading> latestBySite;

  @override
  Widget build(BuildContext context) {
    var redCount = 0;
    var orangeCount = 0;
    var yellowCount = 0;
    var normalCount = 0;
    for (final site in sites) {
      final reading = latestBySite[site.siteId];
      final level = reading?.manualLevel ?? reading?.aiDetectedLevel;
      switch (Reading.calculateWarningLevel(level, site.dangerLevel)) {
        case 'red':
          redCount++;
          break;
        case 'orange':
          orangeCount++;
          break;
        case 'yellow':
          yellowCount++;
          break;
        default:
          normalCount++;
      }
    }

    final Color borderColor;
    if (redCount > 0) {
      borderColor = Colors.red;
    } else if (orangeCount > 0) {
      borderColor = Colors.orange;
    } else if (yellowCount > 0) {
      borderColor = Colors.amber.shade700;
    } else {
      borderColor = AppColors.outlineVariant;
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
        border: Border.all(
          color: borderColor,
          width: redCount + orangeCount + yellowCount > 0 ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            abbr,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${sites.length} site${sites.length == 1 ? '' : 's'}',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (redCount > 0) _WarningDot(color: Colors.red, count: redCount),
              if (orangeCount > 0)
                _WarningDot(color: Colors.orange, count: orangeCount),
              if (yellowCount > 0)
                _WarningDot(color: Colors.amber.shade700, count: yellowCount),
              if (normalCount > 0)
                _WarningDot(color: Colors.green, count: normalCount),
            ],
          ),
        ],
      ),
    );
  }
}

class _WarningDot extends StatelessWidget {
  const _WarningDot({required this.color, required this.count});

  final Color color;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 3),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _SiteLevelEntry {
  const _SiteLevelEntry(
    this.site,
    this.level,
    this.rateOfRisePerHour,
    this.hasEnoughReadingsForRate,
  );

  final Site site;
  final double level;
  // null when hasEnoughReadingsForRate is false (fewer than 2 usable
  // readings for this site) — see _rateOfRiseDisplay/_dangerEtaPill below.
  final double? rateOfRisePerHour;
  final bool hasEnoughReadingsForRate;
}

// ---- Feature 1: Rate of Rise ----
//
// Uses the two most recent readings (by timestamp) with a usable level for
// a site to compute a simple linear rate of change, in meters/hour.
// [newestFirstReadings] must already be sorted newest-first.
double? _rateOfRisePerHour(List<Reading> newestFirstReadings) {
  if (newestFirstReadings.length < 2) return null;
  final latest = newestFirstReadings[0];
  final previous = newestFirstReadings[1];
  final latestLevel = latest.manualLevel ?? latest.aiDetectedLevel;
  final previousLevel = previous.manualLevel ?? previous.aiDetectedLevel;
  if (latestLevel == null || previousLevel == null) return null;
  final hours =
      latest.timestamp.difference(previous.timestamp).inMinutes / 60.0;
  if (hours <= 0) return null;
  return (latestLevel - previousLevel) / hours;
}

({String text, Color color, bool bold}) _rateOfRiseDisplay(
  double? rate,
  bool hasEnoughReadings,
) {
  if (!hasEnoughReadings || rate == null) {
    return (
      text: 'Insufficient data',
      color: Colors.grey.shade600,
      bold: false,
    );
  }
  if (rate > 0.5) {
    return (
      text: 'Rising fast +${rate.toStringAsFixed(1)}m/hr',
      color: Colors.red.shade700,
      bold: true,
    );
  }
  if (rate >= 0.1) {
    return (
      text: 'Rising +${rate.toStringAsFixed(1)}m/hr',
      color: Colors.orange.shade800,
      bold: false,
    );
  }
  if (rate <= -0.1) {
    // rate is already negative, so toStringAsFixed already includes the
    // "-" sign — no need to prepend one as with the rising cases above.
    return (
      text: 'Falling ${rate.toStringAsFixed(1)}m/hr',
      color: Colors.green.shade700,
      bold: false,
    );
  }
  return (text: 'Stable', color: Colors.grey.shade600, bold: false);
}

// ---- Feature 2: Time to Danger ----
//
// Returns null when the site is already in alert, the rate isn't
// positive, or the estimate is 24h+ out — in every one of those cases the
// pill simply isn't shown, per spec.
Widget? _dangerEtaPill(double? rate, double currentLevel, double dangerLevel) {
  if (rate == null || rate <= 0) return null;
  if (currentLevel >= dangerLevel) return null;

  final hoursRemaining = (dangerLevel - currentLevel) / rate;
  if (hoursRemaining >= 24) return null;

  final Color color;
  final String text;
  if (hoursRemaining < 2) {
    final totalMinutes = (hoursRemaining * 60).round();
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    text = 'Danger in ~${h}h ${m}m';
    color = Colors.red.shade700;
  } else if (hoursRemaining < 6) {
    text = 'Danger in ~${hoursRemaining.round()}h';
    color = Colors.orange.shade800;
  } else {
    text = 'Danger in ~${hoursRemaining.round()}h';
    color = Colors.amber.shade800;
  }

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      border: Border.all(color: color),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 10),
    ),
  );
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
    // feeds the rest of this dashboard), so each per-site list built below
    // preserves that order too — readingsBySite[x].first is that site's
    // latest usable reading, .first/.second feed the rate-of-rise calc.
    final readingsBySite = <String, List<Reading>>{};
    for (final r in allReadings) {
      final level = r.manualLevel ?? r.aiDetectedLevel;
      if (level == null) continue;
      (readingsBySite[r.siteId] ??= []).add(r);
    }

    final rows = <_SiteLevelEntry>[];
    for (final site in sites) {
      final siteReadings = readingsBySite[site.siteId];
      if (siteReadings == null || siteReadings.isEmpty) continue;
      final level =
          siteReadings.first.manualLevel ?? siteReadings.first.aiDetectedLevel;
      if (level == null) continue;
      rows.add(
        _SiteLevelEntry(
          site,
          level,
          _rateOfRisePerHour(siteReadings),
          siteReadings.length >= 2,
        ),
      );
    }
    rows.sort((a, b) => b.level.compareTo(a.level));

    if (rows.isEmpty) {
      return const SizedBox(
        height: 60,
        child: Center(
          child: Text(
            'No recent level readings yet',
            style: TextStyle(color: Color(0xFF1A1A1A)),
          ),
        ),
      );
    }

    final maxScale = rows.fold<double>(
      0,
      (acc, r) =>
          [acc, r.level, r.site.dangerLevel].reduce((a, b) => a > b ? a : b),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: Text(
                        row.site.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1A1A1A),
                        ),
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
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                  ],
                ),
                // Feature 1: rate of rise, below the site name.
                Builder(
                  builder: (context) {
                    final rateInfo = _rateOfRiseDisplay(
                      row.rateOfRisePerHour,
                      row.hasEnoughReadingsForRate,
                    );
                    return Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        rateInfo.text,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: rateInfo.bold
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: rateInfo.color,
                        ),
                      ),
                    );
                  },
                ),
                // Feature 2: time-to-danger pill, below the rate-of-rise
                // line — omitted entirely (per spec) when not applicable.
                Builder(
                  builder: (context) {
                    final pill = _dangerEtaPill(
                      row.rateOfRisePerHour,
                      row.level,
                      row.site.dangerLevel,
                    );
                    if (pill == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: pill,
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Calendar-heatmap-style view of reading submission activity over the last
/// 30 days — one square per day, darker for more readings that day. Fed
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

    final maxCount = countByDay.values.fold<int>(0, (a, b) => a > b ? a : b);

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
