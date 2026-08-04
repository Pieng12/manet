import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart'; // Import Geolocator directly for map view updates
import 'package:pkmproject/models/sos_message.dart';
import 'package:intl/intl.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class SosMapView extends StatefulWidget {
  final List<SOSMessage> messages;

  const SosMapView({super.key, required this.messages});

  @override
  State<SosMapView> createState() => _SosMapViewState();
}

class _SosMapViewState extends State<SosMapView> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  bool _isOffline = false;
  LatLng? _currentLocation;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<Position>? _positionStream;

  // Pulse animation controller
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      _updateConnectivityStatus(results);
    });

    _startLocationUpdates();

    // Setup pulse animation for current location
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _pulseAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _positionStream?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _startLocationUpdates() async {
    // Get initial position
    try {
      final position = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude);
        });
      }
    } catch (e) {
      // Permission might be denied, handled elsewhere or just don't show marker
    }

    // Listen to updates
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen((Position position) {
          if (mounted) {
            setState(() {
              _currentLocation = LatLng(position.latitude, position.longitude);
            });
          }
        });
  }

  Future<void> _checkConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    _updateConnectivityStatus(results);
  }

  void _updateConnectivityStatus(List<ConnectivityResult> results) {
    final isOffline = results.every(
      (result) => result == ConnectivityResult.none,
    );
    if (mounted) {
      setState(() {
        _isOffline = isOffline;
      });
    }
  }

  bool get _hasValidLocations =>
      widget.messages.any((m) => m.latitude != 0.0 || m.longitude != 0.0);

  LatLng get _center {
    if (_currentLocation != null) {
      return _currentLocation!; // Prioritize user location if available
    }

    final withLocation = widget.messages
        .where((m) => m.latitude != 0.0 || m.longitude != 0.0)
        .toList();
    if (withLocation.isEmpty) {
      return const LatLng(0, 0);
    }
    final avgLat =
        withLocation.map((m) => m.latitude).reduce((a, b) => a + b) /
        withLocation.length;
    final avgLon =
        withLocation.map((m) => m.longitude).reduce((a, b) => a + b) /
        withLocation.length;
    return LatLng(avgLat, avgLon);
  }

  Map<String, List<SOSMessage>> _clusteredMessages() {
    const grid = 0.001; // ~100m
    final Map<String, List<SOSMessage>> buckets = {};
    for (final m in widget.messages) {
      if (m.latitude == 0.0 && m.longitude == 0.0) continue;
      final keyLat = (m.latitude / grid).round() * grid;
      final keyLon = (m.longitude / grid).round() * grid;
      final key = '$keyLat,$keyLon';
      buckets.putIfAbsent(key, () => []).add(m);
    }
    return buckets;
  }

  void _showClusterDetailsSheet(
    BuildContext context,
    List<SOSMessage> clusterMessages,
    LatLng point,
  ) {
    final dateFormat = DateFormat('MMM dd, yyyy HH:mm');

    showModalBottomSheet(
      context: context,
      backgroundColor: ResqColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: ResqColors.line,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const Icon(Icons.place, size: 18, color: ResqColors.ember),
                    const SizedBox(width: 8),
                    const Text(
                      'SOS at this location',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'x${clusterMessages.length}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: ResqColors.ember,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: clusterMessages.length,
                    separatorBuilder: (context, index) =>
                        Divider(color: Colors.grey.shade800, height: 12),
                    itemBuilder: (context, index) {
                      final m = clusterMessages[index];
                      final isActive = m.status == SOSMessageStatus.active;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? ResqColors.danger.withValues(alpha: 0.16)
                                  : ResqColors.safe.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              isActive
                                  ? Icons.warning_amber_rounded
                                  : Icons.check_circle,
                              size: 18,
                              color: isActive
                                  ? ResqColors.danger
                                  : ResqColors.safe,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        m.senderName ?? m.senderId,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      dateFormat.format(
                                        DateTime.fromMillisecondsSinceEpoch(
                                          m.updatedAt,
                                        ),
                                      ),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  m.content,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasValidLocations && _currentLocation == null) {
      final hasMessages = widget.messages.isNotEmpty;
      return Container(
        decoration: BoxDecoration(
          color: ResqColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ResqColors.line),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.map_outlined, color: ResqColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasMessages
                    ? 'Messages found (${widget.messages.length}), but they have no valid location data (0,0).'
                    : 'Map waiting for location...',
                style: TextStyle(
                  color: hasMessages ? ResqColors.danger : ResqColors.muted,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final buckets = _clusteredMessages();

    // Use FMTC store
    final tileProvider = FMTCStore('mapStore').getTileProvider();

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 15,
              minZoom: 2,
              maxZoom: 18.4, // Enable high zoom
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'id.ac.usu.resqmesh',
                tileProvider: tileProvider, // Use offline caching tile provider
              ),
              // Current Location Marker Layer (Bottom)
              if (_currentLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentLocation!,
                      width: 60,
                      height: 60,
                      child: AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              // Pulse ring
                              Transform.scale(
                                scale: 1.0 + (_pulseAnimation.value * 0.5),
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: ResqColors.signal.withValues(
                                      alpha: 0.3 * (1 - _pulseAnimation.value),
                                    ),
                                  ),
                                ),
                              ),
                              // Solid dot
                              Container(
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: ResqColors.signal,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              // SOS Markers Layer (Top)
              MarkerLayer(
                markers: buckets.entries.map((entry) {
                  final parts = entry.key.split(',');
                  final lat = double.parse(parts[0]);
                  final lon = double.parse(parts[1]);
                  final count = entry.value.length;
                  final hasActive = entry.value.any(
                    (m) => m.status == SOSMessageStatus.active,
                  );
                  final point = LatLng(lat, lon);

                  return Marker(
                    point: point,
                    width: 44,
                    height: 44,
                    child: GestureDetector(
                      onTap: () =>
                          _showClusterDetailsSheet(context, entry.value, point),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: hasActive
                                ? [ResqColors.danger, ResqColors.ember]
                                : [ResqColors.signal, ResqColors.safe],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: hasActive
                                  ? ResqColors.danger.withValues(alpha: 0.45)
                                  : ResqColors.signal.withValues(alpha: 0.35),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$count',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          // Offline Indicator (Top Center)
          if (_isOffline)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: ResqColors.ink.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ResqColors.line, width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.wifi_off_rounded,
                        color: Colors.orangeAccent,
                        size: 16,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Offline mode - cached map',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Current Location Button (Bottom Right)
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.small(
              backgroundColor: ResqColors.surfaceRaised,
              foregroundColor: Colors.white,
              child: const Icon(Icons.my_location),
              onPressed: () {
                if (_currentLocation != null) {
                  _mapController.move(_currentLocation!, 16);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
