class User {
  final String uid;
  final String name;
  final String email;
  final String role;
  final List<String> assignedSiteIds;

  User({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.assignedSiteIds,
  });

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      uid: map['uid'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
      role: map['role'] as String,
      assignedSiteIds: List<String>.from(map['assignedSiteIds'] as List),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'role': role,
      'assignedSiteIds': assignedSiteIds,
    };
  }
}
