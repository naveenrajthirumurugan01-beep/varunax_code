// Valid values for [User.role]: 'field', 'supervisor', 'analyst', 'citizen'.
class User {
  final String uid;
  final String name;
  final String email;
  final String role;
  final List<String> assignedSiteIds;
  // Citizen-reporter fields — null for every other role.
  final String? registeredZone;
  final double? registeredZoneRadius;
  // Geofence anchor for registeredZoneRadius — a zone name alone (e.g.
  // "Palavakkam, Chennai") has no coordinates to measure distance against,
  // so this is captured from the device's GPS at registration time.
  final double? registeredZoneLatitude;
  final double? registeredZoneLongitude;

  User({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.assignedSiteIds,
    this.registeredZone,
    this.registeredZoneRadius = 5000,
    this.registeredZoneLatitude,
    this.registeredZoneLongitude,
  });

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      uid: map['uid'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
      role: map['role'] as String,
      assignedSiteIds: List<String>.from(map['assignedSiteIds'] as List),
      registeredZone: map['registeredZone'] as String?,
      registeredZoneRadius:
          (map['registeredZoneRadius'] as num?)?.toDouble() ?? 5000,
      registeredZoneLatitude: (map['registeredZoneLatitude'] as num?)
          ?.toDouble(),
      registeredZoneLongitude: (map['registeredZoneLongitude'] as num?)
          ?.toDouble(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'role': role,
      'assignedSiteIds': assignedSiteIds,
      'registeredZone': registeredZone,
      'registeredZoneRadius': registeredZoneRadius,
      'registeredZoneLatitude': registeredZoneLatitude,
      'registeredZoneLongitude': registeredZoneLongitude,
    };
  }
}
