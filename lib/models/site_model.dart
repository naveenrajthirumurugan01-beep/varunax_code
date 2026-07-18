class Site {
  final String siteId;
  final String name;
  final double latitude;
  final double longitude;
  final double allowedRadius;
  final String qrCode;
  final String siteCode;
  final String riverName;
  final double dangerLevel;
  final double? minGaugeHeight;
  final double? maxGaugeHeight;
  // Calibration for a camera frame that only shows part of the gauge —
  // the real-world level at the frame's top edge and bottom edge,
  // respectively (unlike minGaugeHeight/maxGaugeHeight, which describe the
  // gauge's full physical range regardless of what the camera can see).
  final double? visibleRangeTop;
  final double? visibleRangeBottom;
  // Optional CWC-format export fields — populated manually per site when
  // known; left null (rendered as "-"/"0" in the export) otherwise.
  final String? basin;
  final double? rlOfZeroGauge;
  final double? meanSeaLevel;
  // Sites immediately downstream on the same river network — read by
  // CascadeAlertService when this site triggers isAlert to flag those
  // sites as "Elevated Risk" even while their own readings are normal.
  final List<String> downstreamSiteIds;

  Site({
    required this.siteId,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.allowedRadius,
    required this.qrCode,
    required this.siteCode,
    required this.riverName,
    required this.dangerLevel,
    this.minGaugeHeight,
    this.maxGaugeHeight,
    this.visibleRangeTop,
    this.visibleRangeBottom,
    this.basin,
    this.rlOfZeroGauge,
    this.meanSeaLevel,
    this.downstreamSiteIds = const [],
  });

  factory Site.fromMap(Map<String, dynamic> map) {
    return Site(
      siteId: map['siteId'] as String,
      name: map['name'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      allowedRadius: (map['allowedRadius'] as num).toDouble(),
      qrCode: map['qrCode'] as String,
      siteCode: map['siteCode'] as String,
      riverName: map['riverName'] as String,
      dangerLevel: (map['dangerLevel'] as num).toDouble(),
      minGaugeHeight: (map['minGaugeHeight'] as num?)?.toDouble(),
      maxGaugeHeight: (map['maxGaugeHeight'] as num?)?.toDouble(),
      visibleRangeTop: (map['visibleRangeTop'] as num?)?.toDouble(),
      visibleRangeBottom: (map['visibleRangeBottom'] as num?)?.toDouble(),
      basin: map['basin'] as String?,
      rlOfZeroGauge: (map['rlOfZeroGauge'] as num?)?.toDouble(),
      meanSeaLevel: (map['meanSeaLevel'] as num?)?.toDouble(),
      downstreamSiteIds: map['downstreamSiteIds'] != null
          ? List<String>.from(map['downstreamSiteIds'] as List)
          : const [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'siteId': siteId,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'allowedRadius': allowedRadius,
      'qrCode': qrCode,
      'siteCode': siteCode,
      'riverName': riverName,
      'dangerLevel': dangerLevel,
      'minGaugeHeight': minGaugeHeight,
      'maxGaugeHeight': maxGaugeHeight,
      'visibleRangeTop': visibleRangeTop,
      'visibleRangeBottom': visibleRangeBottom,
      'basin': basin,
      'rlOfZeroGauge': rlOfZeroGauge,
      'meanSeaLevel': meanSeaLevel,
      'downstreamSiteIds': downstreamSiteIds,
    };
  }

  double getCalibratedLevel(double waterLinePercent) {
    // Highest priority: the frame only shows part of the gauge, so
    // waterLinePercent is scaled against what's actually visible rather
    // than the gauge's full physical range.
    if (visibleRangeTop != null && visibleRangeBottom != null) {
      return (visibleRangeTop! - (waterLinePercent / 100.0) * (visibleRangeTop! - visibleRangeBottom!)) + 0.7;
    }
    if (minGaugeHeight != null && maxGaugeHeight != null) {
      final minH = minGaugeHeight!;
      final maxH = maxGaugeHeight!;
      return minH + (maxH - minH) * (1.0 - waterLinePercent / 100.0);
    }
    final minH = minGaugeHeight ?? (dangerLevel * 0.7);
    final maxH = maxGaugeHeight ?? (dangerLevel * 1.15);
    final calibrated = minH + (maxH - minH) * (1.0 - waterLinePercent / 100.0);
    return calibrated;
  }
}
