import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Registers this device for Firebase Cloud Messaging push notifications:
/// requests notification permission (including the Android 13+ runtime
/// prompt), saves the resulting FCM token to the signed-in user's document
/// in the `users` Firestore collection, keeps that token updated whenever it
/// refreshes, and shows a local notification for any push that arrives
/// while the app is in the foreground.
///
/// firebase_messaging has no native implementation for Windows or Linux
/// (only Android, iOS, macOS, and web), and this app deliberately skips web
/// push for now since it works differently and isn't needed yet — see
/// [_isSupportedPlatform]. Calling [initialize] on an unsupported platform
/// is a safe no-op.
class NotificationService {
  static const _androidChannelId = 'varuna_x_default';
  static const _androidChannelName = 'Varuna X Notifications';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  bool get _isSupportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// Requests notification permission, wires up the foreground message and
  /// token-refresh listeners (only once), then fetches and saves the
  /// current FCM token for whichever user is signed in right now.
  ///
  /// Safe to call more than once — e.g. once from `main.dart` at startup
  /// (covers an already-signed-in user reopening the app) and again from
  /// `login_screen.dart` right after a fresh login (so the token gets
  /// attached to whichever account/role was just signed into). Errors are
  /// swallowed: push registration is best-effort and must never crash app
  /// startup or interrupt the login flow that triggered it.
  Future<void> initialize() async {
    if (!_isSupportedPlatform) return;

    try {
      if (!_initialized) {
        await _initLocalNotifications();
        await FirebaseMessaging.instance.requestPermission();
        FirebaseMessaging.onMessage.listen(_showForegroundNotification);
        FirebaseMessaging.instance.onTokenRefresh.listen(
          _saveTokenToFirestore,
        );
        _initialized = true;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _saveTokenToFirestore(token);
      }
    } catch (e) {
      debugPrint('NotificationService.initialize failed: $e');
    }
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const settings = InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(settings: settings);
  }

  Future<void> _saveTokenToFirestore(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      // merge: true so this only ever touches fcmToken, never clobbers the
      // rest of the user's document, and works whether or not the document
      // already exists.
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('NotificationService: failed to save FCM token: $e');
    }
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    const androidDetails = AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      channelDescription: 'Alerts and updates from Varuna X',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _localNotifications.show(
      id: message.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: details,
    );
  }
}
