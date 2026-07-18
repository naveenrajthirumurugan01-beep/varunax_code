import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/reading_model.dart';
import '../models/site_model.dart';
import 'cwc_excel_generator.dart';

/// Fetches every reading across every site (a full export, independent of
/// whatever filter is currently applied on-screen), builds the CWC-format
/// Excel report, and shares/downloads it. Shared by the analyst dashboard
/// and supervisor history screen's "Download Excel" buttons, since both
/// need the exact same fetch-all/generate/share/error-handling flow.
Future<void> exportCwcExcelReport(BuildContext context) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Generating CWC report...')),
        ],
      ),
    ),
  );

  var dialogOpen = true;
  void closeDialog() {
    if (dialogOpen && context.mounted) {
      Navigator.of(context).pop();
      dialogOpen = false;
    }
  }

  try {
    final sitesSnapshot = await FirebaseFirestore.instance
        .collection('sites')
        .get();
    final sites = sitesSnapshot.docs
        .map((doc) => Site.fromMap({...doc.data(), 'siteId': doc.id}))
        .toList();

    final readingsSnapshot = await FirebaseFirestore.instance
        .collection('readings')
        .orderBy('timestamp', descending: true)
        .get();
    final readings = readingsSnapshot.docs
        .map((doc) => Reading.fromMap({...doc.data(), 'readingId': doc.id}))
        .toList();

    final bytes = await CwcExcelGenerator().generateExcel(readings, sites);

    closeDialog();
    if (!context.mounted) return;

    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final dateStamp = '${now.year}-${two(now.month)}-${two(now.day)}';
    final fileName = 'VARUNA_X_CWC_Report_$dateStamp.xlsx';

    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            bytes,
            name: fileName,
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        ],
        fileNameOverrides: [fileName],
      ),
    );
  } catch (e) {
    closeDialog();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to generate report: $e')),
    );
  }
}
