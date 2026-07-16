class Reading {
  final String readingId;
  final String siteId;
  final String submittedBy;
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final String photoUrl;
  final double? manualLevel;
  final double? aiDetectedLevel;
  final String status;
  final String? supervisorNote;
  final bool isAlert;

  Reading({
    required this.readingId,
    required this.siteId,
    required this.submittedBy,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.photoUrl,
    this.manualLevel,
    this.aiDetectedLevel,
    required this.status,
    this.supervisorNote,
    this.isAlert = false,
  });

  factory Reading.fromMap(Map<String, dynamic> map) {
    return Reading(
      readingId: map['readingId'] as String,
      siteId: map['siteId'] as String,
      submittedBy: map['submittedBy'] as String,
      timestamp: map['timestamp'] is DateTime
          ? map['timestamp'] as DateTime
          : (map['timestamp'] as dynamic).toDate() as DateTime,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      photoUrl: map['photoUrl'] as String,
      manualLevel: (map['manualLevel'] as num?)?.toDouble(),
      aiDetectedLevel: (map['aiDetectedLevel'] as num?)?.toDouble(),
      status: map['status'] as String,
      supervisorNote: map['supervisorNote'] as String?,
      isAlert: map['isAlert'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'readingId': readingId,
      'siteId': siteId,
      'submittedBy': submittedBy,
      'timestamp': timestamp,
      'latitude': latitude,
      'longitude': longitude,
      'photoUrl': photoUrl,
      'manualLevel': manualLevel,
      'aiDetectedLevel': aiDetectedLevel,
      'status': status,
      'supervisorNote': supervisorNote,
      'isAlert': isAlert,
    };
  }
}
