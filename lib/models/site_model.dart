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
    };
  }
}
