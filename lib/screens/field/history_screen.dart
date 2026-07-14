import 'package:flutter/material.dart';

/// Placeholder for the field officer's reading history.
///
/// A list of this officer's own past readings (pulled from the `readings`
/// collection, filtered by `submittedBy`) can be wired in later. For now
/// this just reserves the "History" tab in [FieldHomeScreen]'s bottom nav.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              'Your past readings will appear here soon.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
