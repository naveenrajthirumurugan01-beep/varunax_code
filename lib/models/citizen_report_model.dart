// Valid values for [CitizenReport.waterCondition]: 'Normal', 'Rising',
// 'Flooding', 'Receding'.
// Valid values for [CitizenReport.verificationStatus]: 'pending', 'verified',
// 'rejected', 'flagged'.
class CitizenReport {
  final String reportId;
  final String submittedBy;
  final String submitterZone;
  final DateTime timestamp;
  final String photoUrl;
  final String waterCondition;
  final String description;
  final double latitude;
  final double longitude;
  final String verificationStatus;
  final String? verifiedBy;
  final String? verifierNote;
  final String? linkedReadingId;

  CitizenReport({
    required this.reportId,
    required this.submittedBy,
    required this.submitterZone,
    required this.timestamp,
    required this.photoUrl,
    required this.waterCondition,
    required this.description,
    required this.latitude,
    required this.longitude,
    this.verificationStatus = 'pending',
    this.verifiedBy,
    this.verifierNote,
    this.linkedReadingId,
  });

  factory CitizenReport.fromMap(Map<String, dynamic> map) {
    return CitizenReport(
      reportId: map['reportId'] as String,
      submittedBy: map['submittedBy'] as String,
      submitterZone: map['submitterZone'] as String,
      timestamp: map['timestamp'] is DateTime
          ? map['timestamp'] as DateTime
          : (map['timestamp'] as dynamic).toDate() as DateTime,
      photoUrl: map['photoUrl'] as String,
      waterCondition: map['waterCondition'] as String,
      description: map['description'] as String? ?? '',
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      verificationStatus: map['verificationStatus'] as String? ?? 'pending',
      verifiedBy: map['verifiedBy'] as String?,
      verifierNote: map['verifierNote'] as String?,
      linkedReadingId: map['linkedReadingId'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'reportId': reportId,
      'submittedBy': submittedBy,
      'submitterZone': submitterZone,
      'timestamp': timestamp,
      'photoUrl': photoUrl,
      'waterCondition': waterCondition,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'verificationStatus': verificationStatus,
      'verifiedBy': verifiedBy,
      'verifierNote': verifierNote,
      'linkedReadingId': linkedReadingId,
    };
  }
}
