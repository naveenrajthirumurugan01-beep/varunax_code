import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../satellite_overlay_screen.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../services/user_lookup_service.dart';
import '../../utils/report_generator.dart';

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

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final Set<String> _seenAlertIds = {};
  bool _alertsInitialized = false;

  // Compares this snapshot of active alerts against the previous one (tracked
  // via _seenAlertIds) and shows ONE consolidated dialog for all new alerts.
  // The very first snapshot just establishes the baseline — otherwise every
  // pre-existing alert would trigger a popup the moment this screen opens.
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

    // Show ONE dialog regardless of how many new alerts there are.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final siteNames = newAlerts
          .map((r) => siteById[r.siteId]?.name ?? r.siteId)
          .toSet()
          .join(', ');
      final count = newAlerts.length;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(
            '\u26a0\ufe0f Water Level Alert',
            style: TextStyle(color: Color(0xFF000000)),
          ),
          content: Text(
            count == 1
                ? '\u26a0\ufe0f $siteNames has exceeded its danger threshold.'
                : '\u26a0\ufe0f $count new readings exceed the danger threshold\n($siteNames).',
            style: const TextStyle(color: Color(0xFF1A1A1A)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('sites').snapshots(),
      builder: (context, sitesSnapshot) {
        final siteDocs = sitesSnapshot.data?.docs ?? [];
        final siteById = {
          for (final doc in siteDocs)
            doc.id: Site.fromMap({...doc.data(), 'siteId': doc.id}),
        };

        // Same pending-readings query as before, just relocated one level
        // up so its result count can also feed the app bar's pending pill
        // badge, not only the list below.
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('readings')
              .where('status', isEqualTo: 'pending')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, pendingSnapshot) {
            final pendingDocs = pendingSnapshot.data?.docs ?? [];

            final l10n = AppLocalizations.of(context)!;
            return Scaffold(
              appBar: AppBar(
                title: Text(l10n.reviewReadings),
                actions: [
                  if (pendingSnapshot.hasData)
                    Center(child: _CountPill(count: pendingDocs.length)),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.filter_list),
                    tooltip: 'Filter',
                    // Visual only for now — no filter logic behind this yet.
                    onPressed: () {},
                  ),
                ],
              ),
              body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('readings')
                    .where('isAlert', isEqualTo: true)
                    .snapshots(),
                builder: (context, alertSnapshot) {
                  final alertDocs = alertSnapshot.data?.docs ?? [];
                  final alertReadings = alertDocs
                      .map((doc) => Reading.fromMap(
                            {...doc.data(), 'readingId': doc.id},
                          ))
                      .toList()
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

                  _handleAlertReadings(alertReadings, siteById);

                  // ── Single scrollable body ──────────────────────────────────
                  // Alert banner + reading cards are all children of ONE
                  // CustomScrollView so they scroll together continuously.
                  // Nothing is pinned / Expanded so nothing can hide behind
                  // a fixed overlay.
                  if (pendingSnapshot.hasError) {
                    return Center(
                      child: Text(
                        'Failed to load readings: ${pendingSnapshot.error}',
                        style: const TextStyle(color: Color(0xFF1A1A1A)),
                      ),
                    );
                  }
                  if (pendingSnapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final readings = (pendingSnapshot.data?.docs ?? [])
                      .map((doc) => Reading.fromMap(
                            {...doc.data(), 'readingId': doc.id},
                          ))
                      .toList();

                  return CustomScrollView(
                    slivers: [
                      // ── Alert banner (scrolls away with the rest) ──────────
                      if (alertReadings.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _AlertBanner(
                            readings: alertReadings,
                            siteById: siteById,
                          ),
                        ),

                      // ── Empty state ────────────────────────────────────────
                      if (readings.isEmpty)
                        const SliverFillRemaining(
                          child: Center(
                            child: Text(
                              'No pending readings',
                              style: TextStyle(color: Color(0xFF1A1A1A)),
                            ),
                          ),
                        )
                      else
                        // ── Reading cards (one after the other) ───────────────
                        SliverPadding(
                          padding: const EdgeInsets.all(12),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _ReadingCard(
                                reading: readings[index],
                                site: siteById[readings[index].siteId],
                              ),
                              childCount: readings.length,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      ),
      child: Text(
        '$count Pending',
        style: TextStyle(
          color: Colors.orange.shade800,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
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

class _ReadingCard extends StatefulWidget {
  const _ReadingCard({required this.reading, required this.site});

  final Reading reading;
  final Site? site;

  @override
  State<_ReadingCard> createState() => _ReadingCardState();
}

class _ReadingCardState extends State<_ReadingCard> {
  // Phase-3: stream the satellite doc for this reading's site so we can
  // detect a ground-vs-satellite mismatch in real time.
  Map<String, dynamic>? _satelliteData;

  @override
  void initState() {
    super.initState();
    FirebaseFirestore.instance
        .collection('satellite_analysis')
        .doc(widget.reading.siteId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() => _satelliteData = snap.data());
    });
  }

  // Convenience getters that forward to the immutable widget fields so the
  // rest of the build method doesn't need to change.
  Reading get reading => widget.reading;
  Site?   get site    => widget.site;

  Future<void> _approve(BuildContext context) async {
    try {
      await FirebaseFirestore.instance
          .collection('readings')
          .doc(reading.readingId)
          .update({'status': 'approved'});
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to approve: $e')),
      );
    }
  }

  Future<void> _reject(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => const _RejectDialog(),
    );
    if (note == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('readings')
          .doc(reading.readingId)
          .update({
        'status': 'rejected',
        'supervisorNote': note.isEmpty ? null : note,
      });
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to reject: $e')),
      );
    }
  }

  String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  /// Phase-3 mismatch: satellite says critical flood (inundationRatio > 0.6)
  /// but the ground reading is below 70% of the site's danger level.
  bool get _hasMismatch {
    final satData = _satelliteData;
    if (satData == null) return false;
    final riskStatus = (satData['satelliteRiskStatus'] as String?) ?? '';
    if (riskStatus.toLowerCase() != 'critical') return false;
    final groundLevel = reading.aiDetectedLevel ?? reading.manualLevel;
    if (groundLevel == null || site == null) return false;
    return groundLevel < site!.dangerLevel * 0.7;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final siteName = site?.name ?? reading.siteId;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Image.network(
                      reading.photoUrl,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) =>
                          const Center(child: Icon(Icons.broken_image, size: 48)),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: _SitePillOverlay(siteName: siteName),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SiteNameLabel(siteId: reading.siteId),
            const SizedBox(height: 4),
            _SubmitterLabel(
              uid: reading.submittedBy,
              timeText: _formatTimestamp(reading.timestamp),
            ),
            const SizedBox(height: 2),
            Text(
              'Location: ${reading.latitude.toStringAsFixed(5)}, '
              '${reading.longitude.toStringAsFixed(5)}',
              style: textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            _LevelComparison(reading: reading),
            if (reading.phLevel != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Text(
                      'pH: ${reading.phLevel!.toStringAsFixed(1)}',
                      style: const TextStyle(color: Color(0xFF1A1A1A)),
                    ),
                    if (reading.waterQualityStatus != null) ...[
                      const SizedBox(width: 8),
                      _WaterQualityBadge(status: reading.waterQualityStatus!),
                    ],
                  ],
                ),
              ),
            if (reading.isSubmerged) ...[
              const SizedBox(height: 6),
              const Row(
                children: [
                  Icon(Icons.warning, color: Colors.red, size: 16),
                  SizedBox(width: 6),
                  Text(
                    'Gauge Submerged! (Water at/above top of post)',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
            if (reading.isBlurryOrDark) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.image, color: Colors.orange.shade700, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Quality Issue: Image flagged as blurry or dark',
                    style: TextStyle(
                      color: Colors.orange.shade700,
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
            // ── Phase 3: Ground vs Satellite MISMATCH warning ─────────────────
            if (_hasMismatch) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SatelliteOverlayScreen(siteId: reading.siteId),
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade400),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.compare_arrows, color: Colors.orange.shade800, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '⚠️ Ground/Satellite Mismatch — Satellite radar shows CRITICAL '
                          'flood conditions but ground reading is low. Gauge may be '
                          'submerged or misread. Tap to verify with satellite overlay.',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange.shade900,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: Colors.orange.shade800, size: 16),
                    ],
                  ),
                ),
              ),
            ],
            if (reading.isAlert || reading.isSubmerged) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => SatelliteOverlayScreen(siteId: reading.siteId),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.purple.shade300),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.satellite_alt, color: Colors.purple.shade700, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '⚠️ Ground measurements indicate high risk. Tap to cross-verify with Satellite Radar Telemetry.',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.purple.shade800,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: Colors.purple.shade700, size: 16),
                    ],
                  ),
                ),
              ),
            ],
            if (site != null) ...[
              const SizedBox(height: 12),
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
            const SizedBox(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _reject(context),
                  icon: const Icon(Icons.close),
                  label: Text(l10n.reject),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade600,
                    side: BorderSide(color: Colors.red.shade600),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => _approve(context),
                  icon: const Icon(Icons.check),
                  label: Text(l10n.approve),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
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

class _SitePillOverlay extends StatelessWidget {
  const _SitePillOverlay({required this.siteName});

  final String siteName;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      ),
      child: Text(
        siteName,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
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

class _RejectDialog extends StatefulWidget {
  const _RejectDialog();

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject Reading'),
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
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
