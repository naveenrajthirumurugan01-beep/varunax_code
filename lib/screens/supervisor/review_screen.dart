import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/reading_model.dart';
import '../../models/site_model.dart';

class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review Readings')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('readings')
            .where('status', isEqualTo: 'pending')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Failed to load readings: ${snapshot.error}'),
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('No pending readings'));
          }

          final readings = docs
              .map((doc) => Reading.fromMap({...doc.data(), 'readingId': doc.id}))
              .toList();

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: readings.length,
            itemBuilder: (context, index) => _ReadingCard(
              reading: readings[index],
            ),
          );
        },
      ),
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({required this.reading});

  final Reading reading;

  Future<void> _approve(BuildContext context) async {
    try {
      await FirebaseFirestore.instance
          .collection('readings')
          .doc(reading.readingId)
          .update({'status': 'approved'});
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to approve: $e')),
      );
    }
  }

  Future<void> _reject(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => const _RejectDialog(),
    );
    if (note == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('readings')
          .doc(reading.readingId)
          .update({
        'status': 'rejected',
        'supervisorNote': note.isEmpty ? null : note,
      });
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to reject: $e')),
      );
    }
  }

  String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.network(
                  reading.photoUrl,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(child: CircularProgressIndicator());
                  },
                  errorBuilder: (context, error, stackTrace) => const Center(
                    child: Icon(Icons.broken_image, size: 48),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SiteNameLabel(siteId: reading.siteId),
            const SizedBox(height: 4),
            Text('Submitted: ${_formatTimestamp(reading.timestamp)}'),
            Text(
              'Location: ${reading.latitude.toStringAsFixed(5)}, '
              '${reading.longitude.toStringAsFixed(5)}',
            ),
            _LevelComparison(reading: reading),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _reject(context),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _approve(context),
                    icon: const Icon(Icons.check),
                    label: const Text('Approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SiteNameLabel extends StatelessWidget {
  const _SiteNameLabel({required this.siteId});

  final String siteId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future:
          FirebaseFirestore.instance.collection('sites').doc(siteId).get(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final siteName = data != null ? Site.fromMap(data).name : siteId;
        return Text(
          siteName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        );
      },
    );
  }
}

class _LevelComparison extends StatelessWidget {
  const _LevelComparison({required this.reading});

  final Reading reading;

  static const double _mismatchThreshold = 0.5;

  @override
  Widget build(BuildContext context) {
    final manual = reading.manualLevel;
    final ai = reading.aiDetectedLevel;

    if (manual == null && ai == null) {
      return const SizedBox.shrink();
    }

    if (manual != null && ai != null) {
      final mismatch = (manual - ai).abs() > _mismatchThreshold;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'AI: ${ai.toStringAsFixed(1)}m | '
              'Officer: ${manual.toStringAsFixed(1)}m',
              style: TextStyle(
                fontWeight: mismatch ? FontWeight.bold : FontWeight.normal,
                color: mismatch ? Colors.red.shade700 : null,
              ),
            ),
            if (mismatch) ...[
              const SizedBox(width: 6),
              const Text('⚠️ Mismatch'),
            ],
          ],
        ),
      );
    }

    if (manual != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('Manual level: ${manual.toStringAsFixed(1)}m'),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('AI-detected level: ${ai!.toStringAsFixed(1)}m'),
    );
  }
}

class _RejectDialog extends StatefulWidget {
  const _RejectDialog();

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject Reading'),
      content: TextField(
        controller: _noteController,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'Note (optional)',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(context).pop(_noteController.text.trim()),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
