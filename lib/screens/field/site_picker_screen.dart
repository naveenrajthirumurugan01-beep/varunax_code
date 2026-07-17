
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/site_model.dart';
import 'qr_scan_screen.dart';

class SitePickerScreen extends StatelessWidget {
  const SitePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Site')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Active Sites',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                // Visual only for now — no filter logic behind this yet.
                TextButton(onPressed: () {}, child: const Text('Filter')),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('sites')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Failed to load sites: ${snapshot.error}'),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No sites available. Contact your supervisor.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                final sites = docs
                    .map(
                      (doc) => Site.fromMap({...doc.data(), 'siteId': doc.id}),
                    )
                    .toList();

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: sites.length,
                  itemBuilder: (context, index) {
                    final site = sites[index];
                    return _SiteCard(site: site);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SiteCard extends StatelessWidget {
  const _SiteCard({required this.site});

  final Site site;

  void _openQrScan(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => QrScanScreen(site: site)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openQrScan(context),
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.location_on, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(site.name, style: textTheme.bodyLarge),
                    Text(
                      site.riverName,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () => _openQrScan(context),
                child: const Text('Submit Reading'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
