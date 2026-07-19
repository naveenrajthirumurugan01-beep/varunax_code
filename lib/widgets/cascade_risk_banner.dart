import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// "🌊 Cascade Risk Warnings" section, fed by CascadeAlertService's writes
/// to the cascade_warnings collection. Deliberately styled distinctly from
/// the red danger-alert banners elsewhere (_AlertBanner in the analyst
/// dashboard and review_screen.dart) — amber/orange because this is a
/// PREDICTED risk from an upstream reading, not a confirmed measurement at
/// the affected site itself. Renders nothing at all when there are no
/// active warnings, rather than an empty-state placeholder.
class CascadeRiskBanner extends StatelessWidget {
  const CascadeRiskBanner({
    super.key,
    this.compact = false,
    this.onViewRecommendations,
  });

  /// Smaller text/padding for review_screen.dart, where this sits above an
  /// already-dense reading queue rather than at the top of a full
  /// dashboard.
  final bool compact;

  /// When non-null, shows a "See release recommendations below" tappable
  /// link at the bottom of the banner — used only by the analyst
  /// dashboard, which has a Coordinated Release Recommendations section to
  /// link to. Left null everywhere else (e.g. review_screen.dart's
  /// supervisor-facing usage), so the link simply doesn't render there.
  final VoidCallback? onViewRecommendations;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('cascade_warnings')
          .where('status', isEqualTo: 'active')
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          color: Colors.orange.shade50,
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: compact ? 6 : 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.water,
                    color: Colors.orange.shade800,
                    size: compact ? 16 : 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '🌊 Cascade Risk Warnings',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade900,
                      fontSize: compact ? 13 : 15,
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 4 : 6),
              for (final doc in docs)
                _CascadeWarningCard(data: doc.data(), compact: compact),
              if (onViewRecommendations != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: InkWell(
                    onTap: onViewRecommendations,
                    child: Text(
                      'See release recommendations below',
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade900,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CascadeWarningCard extends StatelessWidget {
  const _CascadeWarningCard({required this.data, required this.compact});

  final Map<String, dynamic> data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final affectedSiteName =
        data['affectedSiteName'] as String? ?? 'Unknown site';
    final sourceSiteName = data['sourceSiteName'] as String? ?? 'An upstream site';
    final riverName = data['riverName'] as String? ?? 'the river';
    final estimatedArrivalHours =
        data['estimatedArrivalHours'] as String? ?? 'unknown';

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: compact ? 4 : 6),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '⚠️ Cascade Risk: $affectedSiteName',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: compact ? 12 : 13,
                    color: Colors.orange.shade900,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const _PredictedPill(),
            ],
          ),
          SizedBox(height: compact ? 2 : 4),
          Text(
            'Upstream site $sourceSiteName on $riverName is currently '
            'flooding',
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              color: Colors.orange.shade900,
            ),
          ),
          SizedBox(height: compact ? 1 : 2),
          Text(
            'Estimated arrival: $estimatedArrivalHours',
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w600,
              color: Colors.orange.shade900,
            ),
          ),
        ],
      ),
    );
  }
}

class _PredictedPill extends StatelessWidget {
  const _PredictedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: Colors.amber.shade700),
      ),
      child: Text(
        'PREDICTED',
        style: TextStyle(
          color: Colors.amber.shade900,
          fontWeight: FontWeight.w700,
          fontSize: 9,
        ),
      ),
    );
  }
}
