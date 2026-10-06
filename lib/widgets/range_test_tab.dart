import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/native_bridge_service.dart';
import '../services/range_test_service.dart';
import 'resq_ui.dart';

class RangeTestTab extends StatefulWidget {
  const RangeTestTab({
    super.key,
    this.service,
    this.locationStream,
    this.capabilities,
    this.screenAwake,
    this.requestBluetooth,
    this.showMap = true,
  });
  final RangeTestService? service;
  final Future<Stream<RangeFix>> Function()? locationStream;
  final Future<Map<String, dynamic>> Function()? capabilities;
  final Future<void> Function(bool)? screenAwake;
  final Future<Map<String, dynamic>> Function()? requestBluetooth;
  final bool showMap;
  @override
  State<RangeTestTab> createState() => _RangeTestTabState();
}

class _RangeTestTabState extends State<RangeTestTab>
    with WidgetsBindingObserver {
  late final RangeTestService service;
  StreamSubscription<RangeFix>? _location;
  Timer? _timer;
  Map<String, dynamic> _data = {};
  Map<String, dynamic> _caps = {};
  String? _locationError;
  String? _error;
  bool _busy = false;
  bool _foreground = true;
  bool _tiles = true;
  bool? _awakeState;
  bool _startingLocation = false;
  bool _bluetoothPrompted = false;
  bool _requestingBluetooth = false;
  String? _bluetoothRequestState;
  bool get _pilotActive =>
      const ['prepared', 'running'].contains((_data['run'] as Map?)?['status']);

  @override
  void initState() {
    super.initState();
    service = widget.service ?? RangeTestService();
    WidgetsBinding.instance.addObserver(this);
    _awake(true);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _awake(bool enabled) async {
    if (_awakeState == enabled) return;
    try {
      await (widget.screenAwake ?? NativeBridgeService.setRangeScreenAwake)(
        enabled,
      );
      _awakeState = enabled;
    } catch (_) {}
  }

  Future<void> _startLocation() async {
    if (_location != null ||
        _startingLocation ||
        !_foreground ||
        !_pilotActive) {
      return;
    }
    _startingLocation = true;
    try {
      Stream<RangeFix> stream;
      if (widget.locationStream != null) {
        stream = await widget.locationStream!();
      } else {
        if (!await Geolocator.isLocationServiceEnabled()) {
          throw StateError('Layanan lokasi tidak aktif');
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          throw StateError('Izin lokasi ditolak');
        }
        stream = Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 1),
          ),
        ).map(_fix);
      }
      if (!mounted || !_foreground || !_pilotActive) {
        return;
      }
      _location = stream.listen(
        (fix) async {
          try {
            await service.recordFix(fix);
          } catch (e) {
            if (mounted) {
              setState(() => _error = e.toString());
            }
          }
        },
        onError: (Object error) {
          _location?.cancel();
          _location = null;
          if (mounted) {
            setState(() => _locationError = error.toString());
          }
          unawaited(
            service.diagnostic('LOCATION_UNAVAILABLE', error.toString()),
          );
        },
      );
      if (mounted) {
        setState(() => _locationError = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _locationError = error.toString());
      }
      await service.diagnostic('LOCATION_UNAVAILABLE', error.toString());
    } finally {
      _startingLocation = false;
    }
  }

  RangeFix _fix(Position position) => RangeFix(
    position.timestamp.millisecondsSinceEpoch,
    position.latitude,
    position.longitude,
    position.accuracy,
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _location?.cancel();
      _location = null;
      unawaited(service.cancelPoint('APP_BACKGROUND'));
      _awake(false);
    } else {
      _awake(true);
      _startLocation();
      _refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _location?.cancel();
    unawaited(service.cancelPoint('VIEW_CLOSED').catchError((Object _) {}));
    _awake(false);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy || !_foreground) {
      return;
    }
    _busy = true;
    try {
      await service.refresh();
      var data = await service.snapshot();
      final run = data['run'] as Map?;
      await _awake(
        _foreground && const ['prepared', 'running'].contains(run?['status']),
      );
      final caps =
          await (widget.capabilities ??
              NativeBridgeService.getBleCapabilities)();
      if (caps['nativeScanActive'] != true) {
        await service.cancelPoint('SCANNER_UNAVAILABLE');
        data = await service.snapshot();
      }
      if (mounted) {
        setState(() {
          _data = data;
          _caps = caps;
          _error = null;
        });
        if (caps['bluetoothEnabled'] == false &&
            caps['connectPermission'] == true &&
            caps['bleSupported'] == true &&
            !_bluetoothPrompted &&
            run?['status'] != 'running') {
          _bluetoothPrompted = true;
          unawaited(_requestBluetooth());
        }
        if (_pilotActive && _locationError == null) {
          unawaited(_startLocation());
        } else if (!_pilotActive) {
          await _location?.cancel();
          _location = null;
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _execute(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) {
        ResqFeedback.error(context, error.toString());
      }
    }
  }

  Future<void> _requestBluetooth() async {
    if (_requestingBluetooth || !_foreground || !mounted) return;
    setState(() => _requestingBluetooth = true);
    try {
      final result =
          await (widget.requestBluetooth ??
              NativeBridgeService.requestBluetoothEnable)();
      if (mounted) {
        setState(() => _bluetoothRequestState = result['state']?.toString());
      }
    } catch (_) {
      if (mounted) setState(() => _bluetoothRequestState = 'failed');
    } finally {
      if (mounted) setState(() => _requestingBluetooth = false);
    }
  }

  Widget _bluetoothControl() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Bluetooth mati', style: TextStyle(color: ResqColors.ember)),
      if (_bluetoothRequestState == 'permission_required')
        const Text('Izin Nearby devices diperlukan'),
      if (_bluetoothRequestState == 'unavailable')
        const Text('Bluetooth tidak tersedia'),
      if (_bluetoothRequestState == 'failed')
        const Text('Dialog Bluetooth tidak dapat dibuka'),
      TextButton.icon(
        onPressed: _requestingBluetooth ? null : _requestBluetooth,
        icon: const Icon(Icons.bluetooth),
        label: const Text('Nyalakan Bluetooth'),
      ),
    ],
  );

  Future<void> _sourceDialog() async {
    final run = _data['run'] as Map?;
    final lat = TextEditingController(
      text: run?['source_latitude']?.toString() ?? '',
    );
    final lon = TextEditingController(
      text: run?['source_longitude']?.toString() ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Posisi ESP'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lat,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Latitude'),
            ),
            TextField(
              controller: lon,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Longitude'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final latitude = double.tryParse(lat.text),
        longitude = double.tryParse(lon.text);
    // Dispose after the closing route has released its text fields.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    lat.dispose();
    lon.dispose();
    if (saved == true) {
      await _execute(() async {
        if (latitude == null || longitude == null) {
          throw ArgumentError('Koordinat tidak valid');
        }
        await service.setSource(latitude, longitude, 'manual');
      });
    }
  }

  Future<void> _startPoint(bool scanner) async {
    final horizontal = TextEditingController();
    final height = TextEditingController();
    final note = TextEditingController();
    final form = GlobalKey<FormState>();
    var method = 'tape_measure';
    double? number(String text) =>
        double.tryParse(text.trim().replaceAll(',', '.'));
    String? validate(String? value, {bool signed = false}) {
      if (value == null || value.trim().isEmpty) return null;
      final parsed = number(value);
      return parsed == null || !parsed.isFinite || (!signed && parsed < 0)
          ? 'Masukkan angka meter yang valid'
          : null;
    }

    final measurement = await showDialog<RangePointMeasurement>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pengamatan titik'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: horizontal,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Jarak horizontal manual (m, opsional)',
                  ),
                  validator: validate,
                ),
                TextFormField(
                  controller: height,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Beda tinggi HP - ESP (m, opsional)',
                  ),
                  validator: (value) => validate(value, signed: true),
                ),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Metode pengukuran manual',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'tape_measure',
                      child: Text('Meteran'),
                    ),
                    DropdownMenuItem(
                      value: 'scaled_plan',
                      child: Text('Denah berskala'),
                    ),
                    DropdownMenuItem(
                      value: 'manual_estimate',
                      child: Text('Perkiraan manual'),
                    ),
                  ],
                  onChanged: (value) => method = value ?? method,
                ),
                TextFormField(
                  controller: note,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Catatan titik (opsional)',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Mulai 60 Detik'),
            onPressed: () {
              if (!form.currentState!.validate()) return;
              try {
                Navigator.pop(
                  context,
                  RangePointMeasurement(
                    horizontalM: number(horizontal.text),
                    heightDifferenceM: number(height.text),
                    method: method,
                    note: note.text,
                  ),
                );
              } catch (_) {
                ResqFeedback.error(context, 'Pengukuran tidak valid');
              }
            },
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    horizontal.dispose();
    height.dispose();
    note.dispose();
    if (!mounted || !_foreground || measurement == null) return;
    await _execute(
      () =>
          service.startPoint(scannerActive: scanner, measurement: measurement),
    );
  }

  String _meters(dynamic value) =>
      value is num ? '${value.toStringAsFixed(1)} m' : 'Tidak tersedia';

  String _measurementMethod(dynamic method) => switch (method) {
    'tape_measure' => 'Meteran',
    'scaled_plan' => 'Denah berskala',
    'manual_estimate' => 'Perkiraan manual',
    _ => 'Tidak diisi',
  };

  String _gpsQuality(String? quality) => switch (quality) {
    'not_distinguishable_from_location_uncertainty' =>
      'Jarak dekat belum dapat dibedakan dari ketidakpastian lokasi',
    'source_uncertainty_unknown' => 'Ketidakpastian posisi ESP tidak terukur',
    'gps_estimate' => 'Estimasi GPS; bukan jarak terukur',
    _ => 'Lokasi tidak tersedia atau tidak layak',
  };

  String _seconds(num ms) => '${mathSeconds(ms)} dtk';
  int mathSeconds(num ms) => (ms / 1000).ceil().clamp(0, 1200);
  Widget _value(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(color: ResqColors.muted)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(color: ResqColors.field),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final run = _data['run'] as Map?;
    if (run == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_caps['bluetoothEnabled'] == false) _bluetoothControl(),
          const Text(
            'Pilot belum disiapkan',
            style: TextStyle(color: ResqColors.field),
          ),
        ],
      );
    }
    final now = service.clock.wallTimeMs();
    final position = _data['last_position'] as Map?;
    final fix = position == null
        ? null
        : RangeFix.fromJson(Map<String, dynamic>.from(position));
    final rx = _data['last_receive'] as Map?;
    final points = (_data['points'] as List? ?? []).cast<Map>();
    final active = points.where((v) => v['status'] == 'running').firstOrNull;
    final prepared = run['status'] == 'prepared';
    final ended = const ['finished', 'interrupted'].contains(run['status']);
    final scanner = _caps['nativeScanActive'] == true;
    final age = rx == null ? null : now - (rx['timestamp_ms'] as int);
    final status = ended
        ? 'Sesi selesai'
        : !scanner
        ? 'Scanner bermasalah'
        : age == null || age > 10000
        ? 'Belum ada penerimaan baru'
        : 'Paket masih diterima';
    final distance =
        fix != null && fix.usableAt(now) && run['source_latitude'] != null
        ? Geolocator.distanceBetween(
            (run['source_latitude'] as num).toDouble(),
            (run['source_longitude'] as num).toDouble(),
            fix.latitude,
            fix.longitude,
          )
        : null;
    final gpsQuality = RangeGpsDistance.assess(
      distance,
      fix?.accuracy,
      (run['source_accuracy_m'] as num?)?.toDouble(),
    );
    final measurementPoint = active ?? points.lastOrNull;
    final center = run['source_latitude'] != null
        ? LatLng(
            (run['source_latitude'] as num).toDouble(),
            (run['source_longitude'] as num).toDouble(),
          )
        : fix == null
        // Initial viewport only, never a measured source coordinate.
        ? const LatLng(3.5952, 98.6722)
        : LatLng(fix.latitude, fix.longitude);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          status,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: scanner && !ended ? ResqColors.safe : ResqColors.ember,
          ),
        ),
        _value('Sesi', run['run_id'].toString()),
        if (_caps['bluetoothEnabled'] == false) _bluetoothControl(),
        _value(
          'Estimasi horizontal GPS',
          distance == null
              ? 'Tidak tersedia'
              : '${distance.toStringAsFixed(1)} m',
        ),
        _value(
          'Kualitas jarak GPS',
          _gpsQuality(gpsQuality['gps_distance_quality'] as String?),
        ),
        _value(
          'Jumlah radius akurasi',
          _meters(gpsQuality['gps_accuracy_radii_sum_m']),
        ),
        _value(
          'Akurasi GPS HP',
          fix == null
              ? 'Tidak tersedia'
              : '${fix.accuracy.toStringAsFixed(1)} m${fix.usableAt(now) ? '' : ' (tidak layak)'}',
        ),
        _value(
          'Usia lokasi',
          fix == null ? '-' : _seconds(now - fix.timestampMs),
        ),
        _value(
          'Posisi ESP',
          run['source_position_method']?.toString() ?? 'Belum ditandai',
        ),
        if (run['source_latitude'] != null)
          _value(
            'Koordinat ESP',
            '${run['source_latitude']}, ${run['source_longitude']}',
          ),
        if (fix != null)
          _value(
            'Koordinat HP',
            '${fix.latitude.toStringAsFixed(6)}, ${fix.longitude.toStringAsFixed(6)}',
          ),
        _value(
          'Akurasi posisi ESP',
          run['source_accuracy_m'] == null
              ? 'Tidak terukur'
              : _meters(run['source_accuracy_m']),
        ),
        _value('Paket terakhir', age == null ? '-' : _seconds(age)),
        _value('RSSI', rx?['rssi'] == null ? '-' : '${rx!['rssi']} dBm'),
        _value(
          'PHY aktual',
          rx?['coded_verified'] == true
              ? 'Coded; S2/S8 tidak diketahui'
              : 'Belum terverifikasi',
        ),
        _value('Observasi RX', '${(_data['receives'] as List? ?? []).length}'),
        _value(
          'Sisa sesi',
          run['ends_at_ms'] == null
              ? 'Belum dimulai'
              : _seconds((run['ends_at_ms'] as int) - now),
        ),
        if (ended)
          const Text(
            'Penghentian ESP diperiksa dari log laptop',
            style: TextStyle(color: ResqColors.muted),
          ),
        if (_locationError != null)
          Text(
            'Lokasi tidak tersedia: $_locationError',
            style: const TextStyle(color: ResqColors.ember),
          ),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: ResqColors.danger)),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            IconButton(
              tooltip: 'Posisi ESP manual',
              onPressed: prepared ? _sourceDialog : null,
              icon: const Icon(Icons.edit_location_alt),
            ),
            IconButton(
              tooltip: 'Posisi ESP dari GPS HP',
              onPressed: prepared && fix != null && fix.usableAt(now)
                  ? () => _execute(
                      () => service.setSource(
                        fix.latitude,
                        fix.longitude,
                        'gps',
                        accuracy: fix.accuracy,
                      ),
                    )
                  : null,
              icon: const Icon(Icons.my_location),
            ),
            IconButton(
              tooltip: 'Coba lokasi kembali',
              onPressed: _startLocation,
              icon: const Icon(Icons.gps_fixed),
            ),
            if (widget.showMap)
              IconButton(
                tooltip: 'Tile peta',
                onPressed: () => setState(() => _tiles = !_tiles),
                icon: Icon(_tiles ? Icons.map : Icons.map_outlined),
              ),
          ],
        ),
        if (widget.showMap)
          SizedBox(
            height: 240,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: 17,
                onTap: prepared
                    ? (_, point) => _execute(
                        () => service.setSource(
                          point.latitude,
                          point.longitude,
                          'map_pin',
                        ),
                      )
                    : null,
              ),
              children: [
                if (_tiles)
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'id.ac.usu.resqmesh',
                    errorTileCallback: (_, _, error) {
                      unawaited(
                        service.diagnostic(
                          'MAP_TILE_UNAVAILABLE',
                          error.toString(),
                        ),
                      );
                    },
                  ),
                if (run['source_latitude'] != null && fix != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [center, LatLng(fix.latitude, fix.longitude)],
                        strokeWidth: 2,
                        color: ResqColors.signal,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (run['source_latitude'] != null)
                      Marker(
                        point: center,
                        width: 32,
                        height: 32,
                        child: const Icon(
                          Icons.sensors,
                          color: ResqColors.ember,
                        ),
                      ),
                    if (fix != null)
                      Marker(
                        point: LatLng(fix.latitude, fix.longitude),
                        width: 32,
                        height: 32,
                        child: const Icon(
                          Icons.location_on,
                          color: ResqColors.signal,
                        ),
                      ),
                  ],
                ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (measurementPoint != null) ...[
          _value(
            'Metode manual titik',
            _measurementMethod(measurementPoint['measurement_method']),
          ),
          _value(
            'Horizontal manual titik',
            _meters(measurementPoint['measured_horizontal_m']),
          ),
          _value(
            'Beda tinggi HP - ESP',
            _meters(measurementPoint['height_difference_m']),
          ),
          _value(
            'Jarak 3D dari input manual',
            _meters(measurementPoint['measured_3d_m']),
          ),
        ],
        if (active != null) ...[
          _value(
            'Pengamatan titik',
            _seconds((active['planned_end_ms'] as int) - now),
          ),
          LinearProgressIndicator(
            value: ((now - (active['started_at_ms'] as int)) / 60000).clamp(
              0,
              1,
            ),
          ),
          TextButton.icon(
            onPressed: () =>
                _execute(() => service.cancelPoint('USER_CANCELLED')),
            icon: const Icon(Icons.stop),
            label: const Text('Batalkan Pengamatan'),
          ),
        ] else
          FilledButton.icon(
            onPressed:
                run['status'] == 'running' &&
                    scanner &&
                    (run['ends_at_ms'] as int) - now >=
                        RangeTestService.pointDurationMs
                ? () => _startPoint(scanner)
                : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Mulai Pengamatan'),
          ),
        for (final point in points.reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              point['status'] == 'invalid'
                  ? Icons.warning_amber
                  : point['status'] == 'completed'
                  ? Icons.check_circle_outline
                  : Icons.timer_outlined,
            ),
            title: Text(
              point['status'] == 'completed'
                  ? 'Pengamatan Selesai'
                  : point['status'] == 'invalid'
                  ? 'Pengamatan Dibatalkan'
                  : 'Pengamatan Berjalan',
            ),
            subtitle: Text(
              '${point['receive_count']} observasi - ${point['receive_result'] == 'received' ? 'Paket diterima' : 'Tidak ada penerimaan teramati'}${point['reason'] == null ? '' : ' - ${point['reason']}'}'
              '${point['measured_horizontal_m'] == null ? '' : '\nHorizontal manual: ${_meters(point['measured_horizontal_m'])}'}'
              '${point['measured_3d_m'] == null ? '' : '\n3D manual: ${_meters(point['measured_3d_m'])}'}'
              '${point['measurement_method'] == null ? '' : '\n${_measurementMethod(point['measurement_method'])}'}'
              '${point['point_note'] == null || point['point_note'] == '' ? '' : '\n${point['point_note']}'}',
            ),
          ),
      ],
    );
  }
}
