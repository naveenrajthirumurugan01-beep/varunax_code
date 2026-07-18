import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/site_model.dart';

/// Predicts downstream flood risk when an upstream site triggers a formal
/// alert — purely additive alongside the existing alert flow (Reading
/// .isAlert, PushSenderService.sendAlertPush): this never reads or writes
/// either of those, it only writes a separate "predicted risk" record to
/// the cascade_warnings collection for downstream sites to surface on the
/// analyst/supervisor dashboards.
class CascadeAlertService {
  // No real river flow-velocity data available yet — a fixed placeholder
  // range rather than a fabricated precise number.
  static const _estimatedArrivalHours = '6-12 hours';

  /// Looks up [alertSiteId]'s downstreamSiteIds and writes an active
  /// cascade warning for each one. Fetches every site itself (rather than
  /// requiring the caller to already have the full list) so call sites
  /// like capture_screen.dart don't need a new parameter threaded through.
  /// Never throws — a failed cascade write must not block or fail the
  /// reading submission that triggered it.
  Future<void> checkAndTriggerCascade(String alertSiteId) async {
    try {
      final sitesSnapshot = await FirebaseFirestore.instance
          .collection('sites')
          .get();
      final sites = sitesSnapshot.docs
          .map((doc) => Site.fromMap({...doc.data(), 'siteId': doc.id}))
          .toList();
      final sitesById = {for (final s in sites) s.siteId: s};

      final alertSite = sitesById[alertSiteId];
      if (alertSite == null) return;

      for (final downstreamId in alertSite.downstreamSiteIds) {
        final downstreamSite = sitesById[downstreamId];
        if (downstreamSite == null) continue;

        final warningsCollection = FirebaseFirestore.instance.collection(
          'cascade_warnings',
        );
        await warningsCollection.doc(downstreamId).set({
          // A random id distinct from the doc's own key (affectedSiteId,
          // used so a repeat alert overwrites rather than stacks) —
          // useful if these are ever displayed/logged individually.
          'warningId': warningsCollection.doc().id,
          'sourceSiteId': alertSite.siteId,
          'sourceSiteName': alertSite.name,
          'affectedSiteId': downstreamSite.siteId,
          'affectedSiteName': downstreamSite.name,
          'riverName': alertSite.riverName,
          'timestamp': DateTime.now(),
          'status': 'active',
          'estimatedArrivalHours': _estimatedArrivalHours,
        });
      }
    } catch (e) {
      debugPrint('CascadeAlertService.checkAndTriggerCascade failed: $e');
    }
  }

  /// Marks the cascade warning for [affectedSiteId] as resolved. Never
  /// throws.
  Future<void> clearCascadeWarning(String affectedSiteId) async {
    try {
      await FirebaseFirestore.instance
          .collection('cascade_warnings')
          .doc(affectedSiteId)
          .set({'status': 'cleared'}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('CascadeAlertService.clearCascadeWarning failed: $e');
    }
  }
}
