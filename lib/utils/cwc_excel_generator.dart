import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../models/reading_model.dart';
import '../models/site_model.dart';

/// Generates a CWC-format (.xlsx) telemetry export — the Sheet 1 column
/// order and names match the official CWC CSV/telemetry format exactly, so
/// the output can be handed to CWC systems without reformatting.
class CwcExcelGenerator {
  static const List<String> _headers = [
    'SlNo',
    'Station',
    'Agency',
    'State LGD Code',
    'State',
    'District LGD Code',
    'District',
    'Tehsil',
    'Block',
    'Village',
    'River',
    'Basin',
    'Tributary',
    'Subtributary',
    'SubSubtributary',
    'Local River',
    'Latitude',
    'Longitude',
    'Is_DischargeDataAvailable',
    'RL_of_zeroGauge',
    'MeanSeaLevel',
    'Data Acquisition Time',
    'River Water Level Telemetry Hourly (meter)',
  ];

  // Approximate per-column widths — Station and the timestamp/level columns
  // read wider than the rest, everything else defaults to a narrower width.
  static const Map<int, double> _columnWidths = {
    1: 25, // Station
    21: 20, // Data Acquisition Time
    22: 15, // River Water Level Telemetry Hourly (meter)
  };

  // siteId -> district, for the seeded demo sites where the district is
  // known. Any other/unknown site falls back to "-", matching the official
  // format's own convention for fields it doesn't have data for.
  static const Map<String, String> _districtBySiteId = {
    'site_tn_mettur': 'Salem',
    'site_tn_bhavanisagar': 'Erode',
    'site_tn_vaigai': 'Theni',
    'site_tn_amaravathi': 'Tiruppur',
    'site_tn_papanasam': 'Tirunelveli',
    'site_kl_idukki': 'Idukki',
    'site_kl_mullaperiyar': 'Idukki',
    'site_kl_malampuzha': 'Palakkad',
    'site_kl_banasura': 'Wayanad',
    'site_kl_neyyar': 'Thiruvananthapuram',
    'site_ka_krs': 'Mandya',
    'site_ka_almatti': 'Vijayapura',
    'site_ka_tungabhadra': 'Koppal',
    'site_ka_bhadra': 'Chikkamagaluru',
    'site_ka_linganamakki': 'Shivamogga',
  };

  // siteCode follows "CWC-<STATE>-<NNN>", e.g. "CWC-TN-001" — the middle
  // segment maps to the official LGD state code/name.
  ({String lgdCode, String name}) _stateInfo(String siteCode) {
    final parts = siteCode.split('-');
    final stateAbbr = parts.length >= 2 ? parts[1] : '';
    switch (stateAbbr) {
      case 'TN':
        return (lgdCode: '33', name: 'Tamil Nadu');
      case 'KL':
        return (lgdCode: '32', name: 'Kerala');
      case 'KA':
        return (lgdCode: '29', name: 'Karnataka');
      default:
        return (lgdCode: '-', name: '-');
    }
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  String _formatAcquisitionTime(DateTime dt) =>
      '${_twoDigits(dt.day)}-${_twoDigits(dt.month)}-${dt.year} '
      '${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}';

  double _round8(double value) => double.parse(value.toStringAsFixed(8));

  Future<Uint8List> generateExcel(
    List<Reading> readings,
    List<Site> sites,
  ) async {
    final siteById = {for (final s in sites) s.siteId: s};

    final excel = Excel.createExcel();
    const dataSheetName = 'CWC Telemetry Data';
    const summarySheetName = 'Summary';
    excel.rename('Sheet1', dataSheetName);
    final dataSheet = excel[dataSheetName];

    dataSheet.appendRow([for (final h in _headers) TextCellValue(h)]);
    for (var c = 0; c < _headers.length; c++) {
      dataSheet
              .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
              .cellStyle =
          CellStyle(bold: true);
      dataSheet.setColumnWidth(c, _columnWidths[c] ?? 12);
    }

    var slNo = 1;
    for (final reading in readings) {
      final site = siteById[reading.siteId];
      final stateInfo = _stateInfo(site?.siteCode ?? '');
      final district = site != null
          ? (_districtBySiteId[site.siteId] ?? '-')
          : '-';
      final level = reading.manualLevel ?? reading.aiDetectedLevel;
      final rlOfZeroGauge = site?.rlOfZeroGauge;
      final meanSeaLevel = site?.meanSeaLevel;

      dataSheet.appendRow([
        IntCellValue(slNo),
        TextCellValue(site?.name ?? reading.siteId),
        TextCellValue('CWC'),
        TextCellValue(stateInfo.lgdCode),
        TextCellValue(stateInfo.name),
        TextCellValue('-'), // District LGD Code
        TextCellValue(district),
        TextCellValue('-'), // Tehsil
        TextCellValue('-'), // Block
        TextCellValue('-'), // Village
        TextCellValue(site?.riverName ?? '-'),
        TextCellValue(site?.basin ?? '-'),
        TextCellValue('-'), // Tributary
        TextCellValue('-'), // Subtributary
        TextCellValue('-'), // SubSubtributary
        TextCellValue('-'), // Local River
        site != null
            ? DoubleCellValue(_round8(site.latitude))
            : TextCellValue('-'),
        site != null
            ? DoubleCellValue(_round8(site.longitude))
            : TextCellValue('-'),
        TextCellValue('No'),
        rlOfZeroGauge != null
            ? DoubleCellValue(rlOfZeroGauge)
            : TextCellValue('0'),
        meanSeaLevel != null
            ? DoubleCellValue(meanSeaLevel)
            : TextCellValue('0'),
        TextCellValue(_formatAcquisitionTime(reading.timestamp)),
        level != null ? DoubleCellValue(level) : TextCellValue('-'),
      ]);
      slNo++;
    }

    _buildSummarySheet(excel, summarySheetName, readings, sites);

    final bytes = excel.encode();
    if (bytes == null) {
      throw StateError('Failed to encode CWC Excel report.');
    }
    return Uint8List.fromList(bytes);
  }

  void _buildSummarySheet(
    Excel excel,
    String sheetName,
    List<Reading> readings,
    List<Site> sites,
  ) {
    final sheet = excel[sheetName];

    sheet.appendRow([
      TextCellValue('CWC Water Level Monitoring Report — VARUNA X'),
    ]);
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
            .cellStyle =
        CellStyle(bold: true);

    sheet.appendRow([
      TextCellValue('Generated: ${_formatAcquisitionTime(DateTime.now())}'),
    ]);

    sheet.appendRow([TextCellValue('')]); // spacer row

    const summaryHeaders = [
      'Site Name',
      'River',
      'Total Readings',
      'Min Level',
      'Max Level',
      'Avg Level',
      'Alerts Count',
      'Danger Threshold',
    ];
    sheet.appendRow([for (final h in summaryHeaders) TextCellValue(h)]);
    final headerRowIndex = sheet.maxRows - 1;
    for (var c = 0; c < summaryHeaders.length; c++) {
      sheet
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: c,
                  rowIndex: headerRowIndex,
                ),
              )
              .cellStyle =
          CellStyle(bold: true);
    }

    for (final site in sites) {
      final siteReadings = readings
          .where((r) => r.siteId == site.siteId)
          .toList();
      if (siteReadings.isEmpty) continue;

      final levels = siteReadings
          .map((r) => r.manualLevel ?? r.aiDetectedLevel)
          .whereType<double>()
          .toList();
      final minLevel = levels.isEmpty
          ? null
          : levels.reduce((a, b) => a < b ? a : b);
      final maxLevel = levels.isEmpty
          ? null
          : levels.reduce((a, b) => a > b ? a : b);
      final avgLevel = levels.isEmpty
          ? null
          : levels.reduce((a, b) => a + b) / levels.length;
      final alertsCount = siteReadings.where((r) => r.isAlert).length;

      sheet.appendRow([
        TextCellValue(site.name),
        TextCellValue(site.riverName),
        IntCellValue(siteReadings.length),
        minLevel != null ? DoubleCellValue(minLevel) : TextCellValue('-'),
        maxLevel != null ? DoubleCellValue(maxLevel) : TextCellValue('-'),
        avgLevel != null
            ? DoubleCellValue(double.parse(avgLevel.toStringAsFixed(2)))
            : TextCellValue('-'),
        IntCellValue(alertsCount),
        DoubleCellValue(site.dangerLevel),
      ]);
    }

    for (var c = 0; c < summaryHeaders.length; c++) {
      sheet.setColumnWidth(c, c == 0 ? 25 : 15);
    }
  }
}
