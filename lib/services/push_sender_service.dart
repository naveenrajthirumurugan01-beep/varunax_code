import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:http/http.dart' as http;

/// Sends flood alert push notifications directly from the app via the FCM
/// HTTP v1 API, authenticating with the bundled Firebase Admin service
/// account (assets/service_account.json) instead of going through a Cloud
/// Function.
///
/// SECURITY WARNING: assets/service_account.json is a Firebase Admin SDK
/// credential bundled into the compiled app — anyone with the installed app
/// can extract it and get full admin access to this Firebase project
/// (Firestore, Auth, Storage), not just FCM send rights. This exists as a
/// deliberate hackathon-scope shortcut in place of a server-side Cloud
/// Function; do not carry this pattern into a production build.
class PushSenderService {
  static const _projectId = 'varuna-x-28174';
  static const _scopes = ['https://www.googleapis.com/auth/firebase.messaging'];
  static const _fcmSendUrl =
      'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send';

  auth.AutoRefreshingAuthClient? _client;

  Future<auth.AutoRefreshingAuthClient> _getClient() async {
    final existing = _client;
    if (existing != null) return existing;

    final jsonString = await rootBundle.loadString(
      'assets/service_account.json',
    );
    final credentials = auth.ServiceAccountCredentials.fromJson(
      json.decode(jsonString) as Map<String, dynamic>,
    );

    final client = await auth.clientViaServiceAccount(credentials, _scopes);
    _client = client;
    return client;
  }

  /// Looks up every supervisor/analyst's FCM token and pushes the given
  /// flood alert to each of them. Never throws — a failed push must not
  /// block or fail the reading submission that triggered it.
  Future<void> sendAlertPush(
    String siteName,
    double level,
    double dangerLevel,
  ) async {
    try {
      final usersSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('role', whereIn: ['supervisor', 'analyst'])
          .get();

      final client = await _getClient();
      final body =
          '$siteName has exceeded its danger threshold: '
          '${level}m recorded (limit: ${dangerLevel}m)';

      for (final userDoc in usersSnapshot.docs) {
        final token = userDoc.data()['fcmToken'] as String?;
        if (token == null || token.isEmpty) continue;

        await _sendToToken(client, userDoc.reference, token, body);
      }
    } catch (e) {
      debugPrint('PushSenderService.sendAlertPush failed: $e');
    }
  }

  /// Looks up the rejecting reading's field officer's FCM token and pushes
  /// a rejection notification to them. Never throws — a failed push must
  /// not block or fail the reject action that triggered it.
  Future<void> sendRejectionNotification(
    String fieldOfficerUid,
    String siteName,
    String rejectionNote,
  ) async {
    try {
      final userRef = FirebaseFirestore.instance
          .collection('users')
          .doc(fieldOfficerUid);
      final userDoc = await userRef.get();
      final token = userDoc.data()?['fcmToken'] as String?;
      if (token == null || token.isEmpty) return;

      final client = await _getClient();
      final body = rejectionNote.isEmpty
          ? 'Your submission was rejected. Please retake and resubmit.'
          : 'Your submission was rejected. Reason: $rejectionNote';

      await _sendToToken(
        client,
        userRef,
        token,
        body,
        title: '⚠️ Reading Rejected — $siteName',
      );
    } catch (e) {
      debugPrint('PushSenderService.sendRejectionNotification failed: $e');
    }
  }

  /// Looks up the citizen reporter's FCM token and notifies them of the
  /// outcome of an analyst's review of their report. Never throws — a
  /// failed push must not block or fail the review action that triggered
  /// it.
  Future<void> sendCitizenReportUpdate(
    String citizenUid,
    String status,
    String? note,
  ) async {
    try {
      final userRef = FirebaseFirestore.instance
          .collection('users')
          .doc(citizenUid);
      final userDoc = await userRef.get();
      final token = userDoc.data()?['fcmToken'] as String?;
      if (token == null || token.isEmpty) return;

      final client = await _getClient();
      final String title;
      final String body;
      switch (status) {
        case 'verified':
          title = '✅ Report Accepted';
          body = '✅ Your river report has been accepted by authorities';
          break;
        case 'rejected':
          title = 'Report Not Accepted';
          body = (note == null || note.isEmpty)
              ? 'Report not accepted.'
              : 'Report not accepted. Reason: $note';
          break;
        case 'flagged':
        default:
          title = '⚠️ Report Flagged for Review';
          body = (note == null || note.isEmpty)
              ? 'Your report has been flagged for further review.'
              : 'Your report has been flagged for further review. Note: $note';
      }

      await _sendToToken(client, userRef, token, body, title: title);
    } catch (e) {
      debugPrint('PushSenderService.sendCitizenReportUpdate failed: $e');
    }
  }

  Future<void> _sendToToken(
    http.Client client,
    DocumentReference<Map<String, dynamic>> userRef,
    String token,
    String body, {
    String title = '⚠️ Water Level Alert',
  }) async {
    try {
      final response = await client.post(
        Uri.parse(_fcmSendUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'message': {
            'token': token,
            'notification': {
              'title': title,
              'body': body,
            },
          },
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('PushSenderService: push sent to $token');
        return;
      }

      debugPrint(
        'PushSenderService: push to $token failed '
        '(${response.statusCode}): ${response.body}',
      );

      final status = _errorStatus(response.body);
      if (status == 'UNREGISTERED' || status == 'INVALID_ARGUMENT') {
        await userRef.update({'fcmToken': FieldValue.delete()});
        debugPrint('PushSenderService: removed stale token for $token');
      }
    } catch (e) {
      debugPrint('PushSenderService: push to $token threw: $e');
    }
  }

  String? _errorStatus(String responseBody) {
    try {
      final decoded = json.decode(responseBody) as Map<String, dynamic>;
      final error = decoded['error'] as Map<String, dynamic>?;
      return error?['status'] as String?;
    } catch (_) {
      return null;
    }
  }
}
