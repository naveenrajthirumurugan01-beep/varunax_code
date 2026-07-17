import 'package:cloud_firestore/cloud_firestore.dart';

/// Resolves a Firebase Auth uid (as stored in Reading.submittedBy) to a
/// human-readable "submitted by" label — the user's name, falling back to
/// their email if name is empty/null (same fallback used for the field
/// dashboard's own "Welcome" greeting).
///
/// Memoizes the Future per uid in a static map, so no matter how many
/// reading cards reference the same officer, or how many times a list
/// rebuilds as it scrolls or a live query updates, each uid is only ever
/// looked up once for the lifetime of the app.
class UserLookupService {
  UserLookupService._();

  static final Map<String, Future<String>> _displayNameCache = {};

  static Future<String> getDisplayName(String uid) {
    return _displayNameCache.putIfAbsent(uid, () => _fetchDisplayName(uid));
  }

  static Future<String> _fetchDisplayName(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = doc.data();

      final name = data?['name'] as String?;
      if (name != null && name.trim().isNotEmpty) return name;

      final email = data?['email'] as String?;
      if (email != null && email.trim().isNotEmpty) return email;

      return uid;
    } catch (_) {
      return uid;
    }
  }
}
