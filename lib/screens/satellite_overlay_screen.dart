import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/site_model.dart';
import '../services/satellite_cache_service.dart';

class SatelliteOverlayScreen extends StatefulWidget {
  const SatelliteOverlayScreen({super.key, required this.siteId});

  final String siteId;

  @override
  State<SatelliteOverlayScreen> createState() => _SatelliteOverlayScreenState();
}

class _SatelliteOverlayScreenState extends State<SatelliteOverlayScreen> {
  // ── UI state ────────────────────────────────────────────────────────────────
  bool _showRadarOverlay = true;

  // ── Data holders ────────────────────────────────────────────────────────────
  Site? _site;
  Map<String, dynamic>? _analysisData;
  bool _isOfflineFallback = false;   // true  → data came from Hive cache
  bool _isLoading = true;
  String? _loadError;

  // ── Internal ─────────────────────────────────────────────────────────────────
  final _cache = SatelliteCacheService();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _firestoreSub;

  // ── Lifecycle ─────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _firestoreSub?.cancel();
    super.dispose();
  }

  // ── Bootstrap: load site + start satellite telemetry pipeline ────────────────
  Future<void> _bootstrap() async {
    // 1. Load site document (needed for coordinates and name)
    try {
      final siteSnap = await FirebaseFirestore.instance
          .collection('sites')
          .doc(widget.siteId)
          .get();
      if (!mounted) return;
      if (!siteSnap.exists) {
        setState(() {
          _loadError = 'Site not found.';
          _isLoading = false;
        });
        return;
      }
      _site = Site.fromMap({...siteSnap.data()!, 'siteId': widget.siteId});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Failed to load site: $e';
        _isLoading = false;
      });
      return;
    }

    // 2. Try to show offline cache immediately while waiting for network
    final cached = await _cache.loadAnalysis(widget.siteId);
    if (cached != null && mounted) {
      setState(() {
        _analysisData = cached;
        _isOfflineFallback = true;
        _isLoading = false;
      });
    } else if (mounted) {
      setState(() => _isLoading = false);
    }

    // 3. Subscribe to live Firestore satellite_analysis doc
    _firestoreSub = FirebaseFirestore.instance
        .collection('satellite_analysis')
        .doc(widget.siteId)
        .snapshots()
        .listen((snap) async {
      if (!mounted) return;
      final data = snap.data();
      if (data != null) {
        // Persist fresh data to offline cache
        await _cache.saveAnalysis(widget.siteId, data);
        if (!mounted) return;
        setState(() {
          _analysisData = data;
          _isOfflineFallback = false;
        });
      }
    });

    // 4. Watch connectivity so we update the offline banner in real time
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      final isOnline = !results.contains(ConnectivityResult.none);
      if (isOnline && _isOfflineFallback) {
        // Just went back online — Firestore listener will deliver fresh data,
        // keep showing stale data until it arrives (no flicker).
      }
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────
  Color _riskColor(String status) {
    switch (status.toLowerCase()) {
      case 'critical': return Colors.red;
      case 'warning':  return Colors.orange;
      case 'normal':   return Colors.green;
      default:         return Colors.grey;
    }
  }

  IconData _riskIcon(String status) {
    switch (status.toLowerCase()) {
      case 'critical': return Icons.report_problem;
      case 'warning':  return Icons.warning;
      case 'normal':   return Icons.check_circle;
      default:         return Icons.help_outline;
    }
  }

  /// Semi-transparent fill colour for the bounding-box flood polygon.
  Color _polygonFillColor(String status) {
    switch (status.toLowerCase()) {
      case 'critical': return const Color(0x66DC3232); // vivid red, ~40% opacity
      case 'warning':  return const Color(0x66FF9500); // orange, ~40% opacity
      case 'normal':   return const Color(0x6634C759); // green, ~40% opacity
      default:         return const Color(0x440A84FF); // blue, ~27% opacity
    }
  }

  /// Solid border colour for the bounding-box flood polygon.
  Color _polygonBorderColor(String status) {
    switch (status.toLowerCase()) {
      case 'critical': return const Color(0xFFDC3232);
      case 'warning':  return const Color(0xFFFF9500);
      case 'normal':   return const Color(0xFF34C759);
      default:         return const Color(0xFF0A84FF);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Satellite Analysis')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Satellite Analysis')),
        body: Center(child: Text(_loadError!)),
      );
    }

    final site = _site!;
    final data = _analysisData;

    final double inundationRatio = (data?['inundationRatio'] as num?)?.toDouble() ?? 0.0;
    final String riskStatus     = (data?['satelliteRiskStatus'] as String?) ?? 'unknown';
    final String? overlayUrl    = data?['overlayImageUrl'] as String?;
    final double precipitation  = (data?['precipitationMm'] as num?)?.toDouble() ?? 0.0;

    final double neLat = (data?['northEastLat'] as num?)?.toDouble() ?? (site.latitude  + 0.02);
    final double neLng = (data?['northEastLng'] as num?)?.toDouble() ?? (site.longitude + 0.02);
    final double swLat = (data?['southWestLat'] as num?)?.toDouble() ?? (site.latitude  - 0.02);
    final double swLng = (data?['southWestLng'] as num?)?.toDouble() ?? (site.longitude - 0.02);

    final riskColor = _riskColor(riskStatus);
    final riskIcon  = _riskIcon(riskStatus);
    final isCritical = riskStatus.toLowerCase() == 'critical';

    return Scaffold(
      appBar: AppBar(
        title: Text('${site.name} — Satellite Analysis'),
        actions: [
          if (_isOfflineFallback)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Chip(
                avatar: const Icon(Icons.wifi_off, size: 14, color: Colors.white),
                label: const Text(
                  'Offline — Cached',
                  style: TextStyle(fontSize: 11, color: Colors.white),
                ),
                backgroundColor: Colors.grey.shade600,
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          // ── Base OpenStreetMap ──────────────────────────────────────────────
          FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(site.latitude, site.longitude),
              initialZoom: 13.0,
            ),
            children: [
              // Esri World Imagery — free satellite tile layer, no API key needed
              TileLayer(
                urlTemplate:
                    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'com.digitalrapid.varunax',
                maxZoom: 19,
              ),

              // Cloudinary radar mask overlay (transparent PNG from /satellite_analysis)
              if (_showRadarOverlay && overlayUrl != null && overlayUrl.isNotEmpty)
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(
                      bounds: LatLngBounds(
                        LatLng(swLat, swLng),
                        LatLng(neLat, neLng),
                      ),
                      opacity: 0.65,
                      imageProvider: NetworkImage(overlayUrl),
                    ),
                  ],
                ),

              // ── Programmatic bounding-box flood polygon ────────────────────
              // Always visible when radar toggle is ON.
              // Acts as the "radar zone" even when no Cloudinary PNG exists yet,
              // and as an additional visible boundary ring around the PNG overlay.
              if (_showRadarOverlay)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: [
                        LatLng(neLat, swLng), // NW
                        LatLng(neLat, neLng), // NE
                        LatLng(swLat, neLng), // SE
                        LatLng(swLat, swLng), // SW
                      ],
                      color: _polygonFillColor(riskStatus),
                      borderColor: _polygonBorderColor(riskStatus),
                      borderStrokeWidth: 2.5,
                    ),
                  ],
                ),

              // Site location pin
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(site.latitude, site.longitude),
                    width: 80,
                    height: 80,
                    child: const Icon(
                      Icons.location_on,
                      size: 40,
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
            ],
          ),

          // ── Phase 2 CRITICAL warning banner ────────────────────────────────
          // Displayed prominently at the TOP of the screen when risk is critical
          // so the officer sees it immediately without scrolling.
          if (isCritical)
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(blurRadius: 6, color: Colors.black26),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.report_problem, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '⚠️ Warning: ${precipitation.toStringAsFixed(0)}mm Overnight Rain. '
                        'Satellite predicts CRITICAL flood risk '
                        '(${(inundationRatio * 100).toStringAsFixed(0)}% inundation).',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Bottom telemetry control panel ─────────────────────────────────
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Risk status row + radar toggle switch
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: riskColor.withValues(alpha: 0.12),
                          child: Icon(riskIcon, color: riskColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Risk Status: ${riskStatus.toUpperCase()}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: riskColor,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Inundation: ${(inundationRatio * 100).toStringAsFixed(1)}%',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        // Radar overlay toggle
                        Column(
                          children: [
                            const Text(
                              'Radar',
                              style: TextStyle(fontSize: 10, color: Colors.grey),
                            ),
                            Switch(
                              value: _showRadarOverlay,
                              onChanged: (val) => setState(() => _showRadarOverlay = val),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const Divider(height: 20),

                    // Precipitation + basin span row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _statColumn(
                          label: 'Overnight Rain',
                          value: '${precipitation.toStringAsFixed(1)} mm',
                          icon: Icons.water_drop,
                          color: Colors.blue,
                        ),
                        _statColumn(
                          label: 'Basin Span',
                          value: '${((neLat - swLat).abs() * 111).toStringAsFixed(1)} km',
                          icon: Icons.straighten,
                          color: Colors.teal,
                        ),
                        _statColumn(
                          label: 'Data Source',
                          value: _isOfflineFallback ? 'Cached' : 'Live',
                          icon: _isOfflineFallback
                              ? Icons.wifi_off
                              : Icons.satellite_alt,
                          color: _isOfflineFallback
                              ? Colors.grey
                              : Colors.green,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statColumn({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: Color(0xFF1A1A1A), // explicit dark — never invisible on white card
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }
}
