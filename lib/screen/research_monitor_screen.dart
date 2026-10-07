import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/experiment_event.dart';
import 'package:pkmproject/models/experiment_metrics.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/models/experiment_trial.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/experiment_export_service.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/research_metrics_service.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/widgets/resq_ui.dart';
import 'package:pkmproject/widgets/range_test_tab.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:uuid/uuid.dart';

class ResearchMonitorScreen extends StatefulWidget {
  const ResearchMonitorScreen({super.key});

  @override
  State<ResearchMonitorScreen> createState() => _ResearchMonitorScreenState();
}

class _ResearchMonitorScreenState extends State<ResearchMonitorScreen>
    with SingleTickerProviderStateMixin {
  final _researchService = ResearchSessionService();
  final _metricsService = ResearchMetricsService();
  final _logger = ExperimentLogger();
  final _relayQueue = RelayQueueService();
  final _exporter = ExperimentExportService();
  final _syncService = SyncService();

  late final TabController _tabController;
  Timer? _refreshTimer;

  ExperimentSession? _session;
  ExperimentTrial? _trial;
  ExperimentMetrics? _sessionMetrics;
  ExperimentMetrics? _trialMetrics;
  List<ExperimentEvent> _events = const [];
  Map<String, dynamic> _capabilities = const {};
  int _queueSize = 0;
  int _sosQueueSize = 0;
  int _ackQueueSize = 0;
  int? _earliestNextEligibleAt;
  bool _pendingRelayWork = false;
  String _eventFilter = 'ALL';
  bool _loading = true;
  bool _refreshing = false;
  String _selectedMode = MeshConfig.forwardingMode.logValue;
  Map<String, dynamic> _neighbors = const {};

  final _sessionNameController = TextEditingController(text: 'TRICKLE-H3');
  final _targetHopController = TextEditingController(text: '3');
  final _topologyController = TextEditingController(
    text: 'Android -> Relay -> Destination',
  );
  final _scenarioController = TextEditingController(text: 'HOP-3');
  final _notesController = TextEditingController();
  final _trialNotesController = TextEditingController();
  final _trialTimeoutController = TextEditingController();
  String _nodeRole = 'RELAY';
  String _failureReason = 'NO_DELIVERY';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refresh();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tabController.dispose();
    _sessionNameController.dispose();
    _targetHopController.dispose();
    _topologyController.dispose();
    _scenarioController.dispose();
    _notesController.dispose();
    _trialNotesController.dispose();
    _trialTimeoutController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final session = await _researchService.currentSession();
      if (session != null) {
        await _researchService.applyTimeoutIfNeeded(
          sessionId: session.sessionId,
        );
      }
      final trial = session == null
          ? null
          : await _researchService.currentTrial(sessionId: session.sessionId);
      final events = await _logger.events(
        sessionId: session?.sessionId,
        trialId: trial?.trialId,
        limit: 200,
      );
      final sessionMetrics = session == null
          ? null
          : await _metricsService.loadMetrics(sessionId: session.sessionId);
      final trialMetrics = session == null || trial == null
          ? null
          : await _metricsService.loadMetrics(
              sessionId: session.sessionId,
              trialId: trial.trialId,
            );
      final capabilities = await NativeBridgeService.getBleCapabilities();
      final queueSize = await _relayQueue.queueSize();
      final sosQueueSize = await _relayQueue.queueSizeByType('sos');
      final ackQueueSize = await _relayQueue.queueSizeByType('ack');
      final earliest = await _relayQueue.earliestNextEligibleAt();
      final pendingRelayWork = await NativeBridgeService.hasPendingRelayWork();
      Map<String, dynamic> neighbors = const {};
      if (session?.topologyLabel == 'neighbor_graph_v1') {
        try {
          neighbors = await _ownerCommand('get_neighbor_status');
        } catch (_) {
          neighbors = {'unavailable': true};
        }
      }
      if (!mounted) return;
      setState(() {
        _session = session;
        _trial = trial;
        _events = events;
        _sessionMetrics = sessionMetrics;
        _trialMetrics = trialMetrics;
        _capabilities = capabilities;
        _queueSize = queueSize;
        _sosQueueSize = sosQueueSize;
        _ackQueueSize = ackQueueSize;
        _earliestNextEligibleAt = earliest;
        _pendingRelayWork = pendingRelayWork;
        _neighbors = neighbors;
        if (session != null) _selectedMode = session.forwardingMode;
        _loading = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResqColors.ink,
      appBar: AppBar(
        title: const Text('Research Monitor'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: ResqColors.ember,
          tabs: const [
            Tab(icon: Icon(Icons.sensors), text: 'LIVE'),
            Tab(icon: Icon(Icons.query_stats), text: 'METRICS'),
            Tab(icon: Icon(Icons.assignment), text: 'TRIAL'),
            Tab(icon: Icon(Icons.timeline), text: 'EVENTS'),
            Tab(icon: Icon(Icons.memory), text: 'SYSTEM'),
            Tab(icon: Icon(Icons.route), text: 'UJI JARAK'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildLiveTab(),
                _buildMetricsTab(),
                _buildTrialTab(),
                _buildEventsTab(),
                _buildSystemTab(),
                const RangeTestTab(),
              ],
            ),
    );
  }

  Widget _buildLiveTab() {
    final currentPacket =
        _trialMetrics?.currentPacket ?? _sessionMetrics?.currentPacket;
    return _scroll(
      children: [
        if (_session?.topologyLabel == 'neighbor_graph_v1')
          _section('Status Tetangga Lokal HP', [
            _kv(
              'Skenario',
              _session?.scenarioLabel == 'S0_MAIN'
                  ? 'S0_MAIN (utama)'
                  : '${_session?.scenarioLabel} (pendukung)',
            ),
            _kv('Scope', '${_neighbors['scope'] ?? '-'}'),
            for (final state in (_neighbors['states'] as List? ?? []))
              for (final peer in (state['neighbors'] as Map).entries)
                _kv('Pemancar ${peer.key}', '${peer.value}'),
          ]),
        _section('Experiment Session', [
          _kv('Session', _session?.name ?? 'No active session'),
          _kv('Trial', _trial?.trialCode ?? 'No active trial'),
          _kv('Trial Status', _trial?.status ?? '-'),
          _dropdown(
            label: 'Forwarding Mode',
            value: _selectedMode,
            values: ForwardingMode.values.map((m) => m.logValue).toList(),
            onChanged: _changeMode,
          ),
          _kv('Node Role', _session?.nodeRole ?? _nodeRole),
          _kv('Hop Target', _session?.targetHop?.toString() ?? '-'),
          _kv(
            'Elapsed Time',
            _elapsedLabel(_trial?.startedAt ?? _session?.startedAt),
          ),
        ]),
        _section('Current Packet', [
          if (currentPacket == null)
            _muted('No current packet')
          else ...[
            _kv('Sender CRC', _hexCrc(currentPacket.senderCrc)),
            _kv(
              'Protocol Time',
              currentPacket.protocolTimestampMs?.toString() ?? '-',
            ),
            _kv('Status', currentPacket.status ?? '-'),
            _kv('Packet Type', currentPacket.packetType ?? '-'),
            _kv('Hop In', currentPacket.hopIn?.toString() ?? '-'),
            _kv('Hop Out', currentPacket.hopOut?.toString() ?? '-'),
            _kv(
              'RSSI',
              currentPacket.rssi == null ? '-' : '${currentPacket.rssi} dBm',
            ),
            _kv('From Server', '${currentPacket.fromServer ?? '-'}'),
            _kv('Payload Identity', currentPacket.payloadHash ?? '-'),
            _kv(
              'Received At',
              currentPacket.receivedAtMs == null
                  ? '-'
                  : _time(currentPacket.receivedAtMs!),
            ),
            _kv(
              'Stored At',
              currentPacket.storedAtMs == null
                  ? '-'
                  : _time(currentPacket.storedAtMs!),
            ),
            _kv(
              'Relay Queued At',
              currentPacket.relayQueuedAtMs == null
                  ? '-'
                  : _time(currentPacket.relayQueuedAtMs!),
            ),
            _kv(
              'Advertised At',
              currentPacket.advertisedAtMs == null
                  ? '-'
                  : _time(currentPacket.advertisedAtMs!),
            ),
          ],
        ]),
        _systemSummary(),
        _section('Extended Coded Radio', [
          for (final key in const [
            'requested_mode',
            'configured_mode',
            'ready',
            'primary_phy',
            'secondary_phy',
            'scan_phy',
            'coding_requested',
            'coding_selection_support',
            's8_requirement_accepted',
            'on_air_coding_verified',
            'tx_power_requested_dbm',
            'tx_power_actual_dbm',
            'advertising_interval_ms',
            'last_error',
          ])
            _kv(
              key.replaceAll('_', ' '),
              '${(_capabilities['radio'] as Map?)?[key] ?? '-'}',
            ),
        ]),
      ],
    );
  }

  Widget _buildMetricsTab() {
    if (_session?.topologyLabel == 'neighbor_graph_v1') {
      final summary = _neighbors['network_summary'] as Map?;
      final pairs = summary?['per_receiver'] as List? ?? [];
      return _scroll(
        children: [
          _section('Statistik Network-Wide (Controller)', [
            _kv('Trial', '${summary?['trial_id'] ?? '-'}'),
            _kv('Metode', '${summary?['method'] ?? _selectedMode}'),
            _kv('Skenario', '${summary?['scenario'] ?? _session?.hypothesis}'),
            _kv(
              'Hasil',
              '${summary?['result'] ?? 'Menunggu arsip seluruh node'}',
            ),
            _kv('DSR', '${summary?['dsr_percent'] ?? '-'} %'),
            _kv('E2E pasangan sukses', '${summary?['e2e_mean_ms'] ?? '-'} ms'),
            _kv('LDR', '${summary?['ldr_percent'] ?? '-'} %'),
            _kv(
              'Overhead DATA / CONTROL',
              '${summary?['data_tx'] ?? '-'} / ${summary?['control_tx'] ?? '-'}',
            ),
            _kv('CONTROL sebelum t0', '${summary?['setup_control_tx'] ?? '-'}'),
          ]),
          _section('Penerimaan Pertama per ESP', [
            for (final receiver in [
              'esp-r1a',
              'esp-r1b',
              'esp-r2a',
              'esp-r2b',
              'esp-destination',
            ])
              _kv(
                receiver,
                pairs.any((p) => (p as Map)['receiver'] == receiver)
                    ? '${(pairs.firstWhere((p) => (p as Map)['receiver'] == receiver) as Map)['e2e_latency_ms']} ms'
                    : summary == null
                    ? 'Menunggu arsip'
                    : 'Tidak diterima dalam window',
              ),
          ]),
          _section('Statistik Lokal HP', [
            _kv(
              'SOS accepted',
              '${_trialMetrics?.acceptedCount ?? _sessionMetrics?.acceptedCount ?? 0}',
            ),
            _kv(
              'TX sukses lokal',
              '${_trialMetrics?.txSuccessCount ?? _sessionMetrics?.txSuccessCount ?? 0}',
            ),
            _kv(
              'Tetangga teramati',
              '${(_neighbors['peers'] as List? ?? []).length}',
            ),
          ]),
        ],
      );
    }
    final sessionMetrics = _sessionMetrics;
    if (sessionMetrics == null) {
      return _scroll(
        children: [
          _emptyPanel('Start a research session to calculate metrics.'),
        ],
      );
    }
    final trialMetrics = _trialMetrics;
    final packetMetrics = trialMetrics ?? sessionMetrics;
    final packetScope = trialMetrics == null
        ? 'CURRENT SESSION'
        : 'CURRENT TRIAL';
    return _scroll(
      children: [
        _metricGrid([
          _metric(
            'DSR',
            _percent(sessionMetrics.dsrPercent),
            'CURRENT SESSION',
          ),
          _metric(
            'Initial RX -> Relay',
            _statMs(packetMetrics.localRelayLatencyMs),
            '$packetScope / LOCAL DEVICE',
          ),
          _metric(
            'SOS Logical Duplicate Ratio',
            _percent(packetMetrics.duplicateRatioPercent),
            '$packetScope / LOCAL DEVICE',
          ),
          _metric(
            'TX Success',
            packetMetrics.txSuccessCount.toString(),
            '$packetScope / LOCAL DEVICE',
          ),
          _metric(
            'E2E Latency',
            packetMetrics.e2eRequiresPeerLog
                ? 'Requires peer log'
                : _statMs(packetMetrics.e2eLatencyMs),
            'REQUIRES PEER LOG',
          ),
          _metric(
            'Local TX / Successful Trial',
            sessionMetrics.transmissionOverhead?.toStringAsFixed(2) ?? 'N/A',
            'CURRENT SESSION / LOCAL DEVICE',
          ),
        ]),
        _section('Packet Counts', [
          _kv('Scope', packetScope),
          _kv('Unique Accepted', packetMetrics.acceptedCount.toString()),
          _kv('SOS Logical Duplicate', packetMetrics.duplicateCount.toString()),
          _kv('SOS Stale Received', packetMetrics.staleCount.toString()),
          _kv('Invalid Received', packetMetrics.invalidCount.toString()),
          _kv('ACK Suppressed', packetMetrics.ackSuppressedCount.toString()),
        ]),
        _section(
          'SOS RSSI',
          _statsRows(packetMetrics.rssiStats, suffix: ' dBm'),
        ),
        _section('SOS Hop Metrics', [
          _kv('Scope', packetScope),
          _kv('Max Hop In', packetMetrics.hopInStats.max?.toString() ?? 'N/A'),
          _kv(
            'Mean Hop In',
            packetMetrics.hopInStats.mean?.toStringAsFixed(2) ?? 'N/A',
          ),
          _kv(
            'Max Hop Out',
            packetMetrics.hopOutStats.max?.toString() ?? 'N/A',
          ),
          _kv(
            'Mean Hop Out',
            packetMetrics.hopOutStats.mean?.toStringAsFixed(2) ?? 'N/A',
          ),
          if (packetMetrics.latestHopValidation == null)
            _kv('Hop Validation', 'N/A')
          else
            _kv(
              'Hop Validation',
              packetMetrics.latestHopValidation!.passed
                  ? 'PASS'
                  : 'FAIL expected ${packetMetrics.latestHopValidation!.expectedHopOut} actual ${packetMetrics.latestHopValidation!.hopOut}',
            ),
        ]),
        _section('ACK Metrics', [
          _kv('Scope', packetScope),
          _kv('ACK Received', packetMetrics.ackReceivedCount.toString()),
          _kv('ACK Accepted', packetMetrics.ackAcceptedCount.toString()),
          _kv('ACK Duplicate', packetMetrics.ackDuplicateCount.toString()),
          _kv('ACK Stale', packetMetrics.ackStaleCount.toString()),
          _kv('ACK Invalid', packetMetrics.ackInvalidCount.toString()),
          _kv(
            'ACK Termination Latency',
            _statMs(packetMetrics.ackTerminationLatencyMs),
          ),
        ]),
        _section('Transmission', [
          _kv('Scope', packetScope),
          _kv('TX Attempt Count', packetMetrics.txAttemptCount.toString()),
          _kv('TX Success Count', packetMetrics.txSuccessCount.toString()),
          _kv('Relay Slot Count', packetMetrics.relaySlotCount.toString()),
        ]),
      ],
    );
  }

  Widget _buildTrialTab() {
    return _scroll(
      children: [
        if (_session?.topologyLabel != 'neighbor_graph_v1')
          _section('Experiment Configuration', [
            _textField(_sessionNameController, 'Experiment Name'),
            _kv(
              'Forwarding Mode',
              _session?.forwardingMode ?? MeshConfig.forwardingMode.logValue,
            ),
            _dropdown(
              label: 'Node Role',
              value: _nodeRole,
              values: const [
                'SOURCE',
                'RELAY',
                'DESTINATION',
                'GATEWAY',
                'OBSERVER',
              ],
              onChanged: (value) => setState(() => _nodeRole = value),
            ),
            _textField(
              _targetHopController,
              'Target Hop Count',
              keyboardType: TextInputType.number,
            ),
            _textField(_topologyController, 'Topology Label'),
            _textField(_scenarioController, 'Distance / Scenario Label'),
            _textField(
              _trialTimeoutController,
              'Trial Timeout Seconds',
              keyboardType: TextInputType.number,
            ),
            _textField(_notesController, 'Notes', maxLines: 3),
            _buttonRow([
              _action('START SESSION', Icons.play_arrow, _startSession),
              _action('END SESSION', Icons.stop, _endSession),
            ]),
          ]),
        if (_session?.topologyLabel == 'neighbor_graph_v1')
          _section('Trial Graph', [
            _kv('Trial', _trial?.trialCode ?? '-'),
            _kv('Status', _trial?.status ?? '-'),
            _kv('Metode', _session?.forwardingMode ?? '-'),
            _kv('Skenario', _session?.scenarioLabel ?? '-'),
            _kv('Pemilik trial', 'Controller eksperimen'),
          ]),
        if (_session?.topologyLabel != 'neighbor_graph_v1')
          _section('Trial Controls', [
            _kv('Current Trial', _trial?.trialCode ?? '-'),
            _dropdown(
              label: 'Failure Reason',
              value: _failureReason,
              values: const [
                'NO_DELIVERY',
                'TIMEOUT',
                'DEVICE_ERROR',
                'BLUETOOTH_ERROR',
                'USER_ERROR',
                'OTHER',
              ],
              onChanged: (value) => setState(() => _failureReason = value),
            ),
            _textField(_trialNotesController, 'Trial Notes', maxLines: 2),
            _buttonRow([
              _action('START TRIAL', Icons.play_circle, _startTrial),
              _action(
                'END TRIAL',
                Icons.check_circle,
                () => _finishTrial('SUCCESS'),
              ),
            ]),
            _buttonRow([
              _action('FAILED', Icons.cancel, () => _finishTrial('FAILED')),
              _action('INVALIDATE', Icons.report, _invalidateTrial),
              _action('NEXT TRIAL', Icons.skip_next, _nextTrial),
            ]),
          ]),
        _section('Export', [
          _buttonRow([
            _action('EXPORT TRIAL CSV', Icons.table_chart, _exportTrialCsv),
            _action('EXPORT SESSION CSV', Icons.grid_on, _exportSessionCsv),
          ]),
          _buttonRow([
            _action(
              'EXPORT SESSION JSON',
              Icons.data_object,
              _exportSessionJson,
            ),
          ]),
        ]),
      ],
    );
  }

  Widget _buildEventsTab() {
    final events = _filteredEvents();
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              for (final filter in const [
                'ALL',
                'RX',
                'TX',
                'RELAY',
                'DUPLICATE',
                'STALE',
                'ACK',
                'ERROR',
                'SYSTEM',
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(filter),
                    selected: _eventFilter == filter,
                    onSelected: (_) => setState(() => _eventFilter = filter),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? const ResqEmptyState(
                  icon: Icons.timeline,
                  title: 'No Events',
                  message: 'Start a session/trial and run BLE experiments.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: events.length,
                  itemBuilder: (context, index) => _eventTile(events[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildSystemTab() {
    return _scroll(
      children: [
        _systemSummary(),
        _section('Protocol Invariants', [
          _kv(
            'Manufacturer ID Dart',
            '0x${MeshConfig.manufacturerId.toRadixString(16).toUpperCase()}',
          ),
          _kv('Manufacturer ID Native', _nativeManufacturerLabel()),
          _kv('Manufacturer Match', _manufacturerMatch() ? 'Yes' : 'No'),
          _kv('Inner Payload', '${MeshConfig.protocolLength} bytes'),
          _kv(
            'DATA Frame',
            _session?.topologyLabel == 'neighbor_graph_v1'
                ? '39 bytes'
                : '17 bytes',
          ),
          _kv(
            'Connectable Advertising',
            MeshConfig.connectableAdvertising ? 'Yes' : 'No',
          ),
          _kv('Hop Saturation', MeshConfig.maxProtocolHop.toString()),
          _kv('Network-wide Metrics', 'Requires merged peer logs'),
        ]),
      ],
    );
  }

  Widget _systemSummary() {
    return _section('System State', [
      _kv('Bluetooth Enabled', '${_capabilities['bluetoothEnabled'] ?? '-'}'),
      _kv('Native BLE Scanner', '${_capabilities['scannerAvailable'] ?? '-'}'),
      _kv(
        'Native BLE Advertiser',
        '${_capabilities['nativeAdvertisingStatus'] ?? '-'}',
      ),
      _kv(
        'Foreground Service',
        '${_capabilities['foregroundServiceActive'] ?? '-'}',
      ),
      _kv('Scheduler State', BleAdvertiserService().schedulerState.name),
      _kv(
        'Native Inbox Pending',
        '${_capabilities['pendingNativeInbox'] ?? '-'}',
      ),
      _kv('Relay Queue Total', _queueSize.toString()),
      _kv('SOS Queue', _sosQueueSize.toString()),
      _kv('ACK Queue', _ackQueueSize.toString()),
      _kv(
        'Earliest Next Eligible',
        _earliestNextEligibleAt == null ? '-' : _time(_earliestNextEligibleAt!),
      ),
      _kv('Pending Relay Work', _pendingRelayWork ? 'Yes' : 'No'),
      _kv(
        'Forwarding Mode',
        _session?.forwardingMode ?? MeshConfig.forwardingMode.logValue,
      ),
      _kv('Device Manufacturer', _session?.deviceManufacturer ?? '-'),
      _kv('Device Model', _session?.deviceModel ?? '-'),
      _kv('Android Release', _session?.androidVersion ?? '-'),
      _kv('Android SDK', _session?.androidSdk?.toString() ?? '-'),
      _kv('App Version', _session?.appVersion ?? '-'),
      _kv('App Version Code', _session?.appVersionCode ?? '-'),
      _kv('Build ID', _session?.buildId ?? MeshConfig.buildId),
      _kv('Last Native Error', '${_capabilities['lastErrorCode'] ?? '-'}'),
      _kv('Permission Blocked', _permissionBlockedLabel()),
      _kv('Headless Worker', 'unknown'),
    ]);
  }

  Future<void> _startSession() async {
    final targetHop = int.tryParse(_targetHopController.text.trim()) ?? 0;
    final timeoutSeconds = int.tryParse(_trialTimeoutController.text.trim());
    final metadata = await NativeBridgeService.getDeviceMetadata();
    try {
      await _researchService.startSession(
        forwardingMode: RelayQueueService.modeFromPersistedValue(_selectedMode),
        deviceId: _syncService.deviceId,
        name: _sessionNameController.text,
        nodeRole: _nodeRole,
        targetHop: targetHop,
        topologyLabel: _topologyController.text,
        scenarioLabel: _scenarioController.text,
        notes: _notesController.text,
        trialTimeoutSeconds: timeoutSeconds == null || timeoutSeconds <= 0
            ? null
            : timeoutSeconds,
        deviceManufacturer: metadata['manufacturer']?.toString(),
        deviceModel: metadata['model']?.toString() ?? 'unknown',
        androidVersion: metadata['androidRelease']?.toString() ?? 'unknown',
        androidSdk: _asInt(metadata['androidSdk']),
        appVersion: metadata['appVersionName']?.toString() ?? 'research',
        appVersionCode: metadata['appVersionCode']?.toString(),
        buildId: MeshConfig.buildId,
      );
    } on StateError catch (e) {
      if (mounted) ResqFeedback.error(context, e.message);
      return;
    }
    await _logger.logEvent(
      eventType: 'RESEARCH_SESSION_STARTED',
      deviceId: _syncService.deviceId,
      detail: {'node_role': _nodeRole, 'target_hop': targetHop},
    );
    await _refresh();
  }

  Future<Map<String, dynamic>> _ownerCommand(
    String command, {
    String? mode,
  }) async {
    final id = const Uuid().v4();
    if (!await NativeBridgeService.requestResearchCommand({
      'command': command,
      'command_id': id,
      'mode': ?mode,
    })) {
      throw StateError('Owner scheduler tidak tersedia');
    }
    final db = await DatabaseHelper().database;
    for (var attempt = 0; attempt < 40; attempt++) {
      final rows = await db.query(
        'experiment_commands',
        where: 'command_id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final result = Map<String, dynamic>.from(
          jsonDecode(rows.first['result_json'] as String) as Map,
        );
        if (result['state'] != 'PROCESSING') {
          if (result['ok'] != true) throw StateError('${result['error']}');
          return result;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('Respons owner timeout');
  }

  Future<void> _changeMode(String value) async {
    if (_session == null) {
      if (value == 'trickle_neighbor_status') {
        ResqFeedback.error(
          context,
          'Konfigurasikan profil graph melalui controller terlebih dahulu',
        );
        return;
      }
      setState(() => _selectedMode = value);
      return;
    }
    try {
      await _ownerCommand('set_forwarding_mode', mode: value);
      await _refresh();
    } catch (e) {
      if (mounted) ResqFeedback.error(context, '$e');
    }
  }

  Future<void> _endSession() async {
    final session = _session;
    if (session == null) return;
    try {
      await _researchService.endSession(session.sessionId);
    } on StateError catch (e) {
      if (mounted) ResqFeedback.error(context, e.message);
      return;
    }
    await _refresh();
  }

  Future<void> _startTrial() async {
    final session = _session;
    if (session == null) {
      await _startSession();
    }
    final activeSession = await _researchService.currentSession();
    if (activeSession == null) return;
    try {
      await _researchService.startTrial(
        sessionId: activeSession.sessionId,
        trialCodePrefix: activeSession.name,
        notes: _trialNotesController.text,
      );
    } on StateError catch (e) {
      if (mounted) ResqFeedback.error(context, e.message);
      return;
    }
    await _logger.logEvent(
      eventType: 'RESEARCH_TRIAL_STARTED',
      deviceId: _syncService.deviceId,
    );
    await _refresh();
  }

  Future<void> _finishTrial(String result) async {
    final trial = _trial;
    if (trial == null) return;
    await _researchService.finishTrial(
      trial.trialId,
      result: result,
      failureReason: result == 'FAILED' ? _failureReason : null,
      notes: _trialNotesController.text,
    );
    await _refresh();
  }

  Future<void> _invalidateTrial() async {
    final trial = _trial;
    if (trial == null) return;
    await _researchService.invalidateTrial(
      trial.trialId,
      notes: _trialNotesController.text,
    );
    await _refresh();
  }

  Future<void> _nextTrial() async {
    if (_trial != null && _trial!.status == 'RUNNING') {
      if (mounted) {
        ResqFeedback.error(context, 'Finish the running trial first');
      }
      return;
    }
    await _startTrial();
  }

  Future<void> _exportTrialCsv() async {
    final session = _session;
    final trial = _trial;
    if (session == null || trial == null) return;
    final file = await _exporter.exportCsv(
      sessionId: session.sessionId,
      trialId: trial.trialId,
    );
    if (mounted) ResqFeedback.success(context, 'Exported ${file.path}');
  }

  Future<void> _exportSessionCsv() async {
    final session = _session;
    if (session == null) return;
    final file = await _exporter.exportCsv(sessionId: session.sessionId);
    if (mounted) ResqFeedback.success(context, 'Exported ${file.path}');
  }

  Future<void> _exportSessionJson() async {
    final session = _session;
    if (session == null) return;
    final file = await _exporter.exportJson(sessionId: session.sessionId);
    if (mounted) ResqFeedback.success(context, 'Exported ${file.path}');
  }

  List<ExperimentEvent> _filteredEvents() {
    if (_eventFilter == 'ALL') return _events.reversed.toList();
    return _events.reversed.where((event) {
      final type = event.eventType;
      return switch (_eventFilter) {
        'RX' => type.contains('RECEIVED') || type.contains('STORED'),
        'TX' => type.contains('ADVERTISE'),
        'RELAY' => type.contains('RELAY'),
        'DUPLICATE' => type.contains('DUPLICATE'),
        'STALE' => type.contains('STALE') || type.contains('OLDER'),
        'ACK' => type.contains('ACK'),
        'ERROR' =>
          type.contains('FAILED') ||
              type.contains('DROPPED') ||
              type.contains('INVALID'),
        'SYSTEM' =>
          type.contains('SERVICE') ||
              type.contains('SCHEDULER') ||
              type.contains('NATIVE'),
        _ => true,
      };
    }).toList();
  }

  Widget _scroll({required List<Widget> children}) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final child in children)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _metricGrid(List<Widget> cards) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.35,
      children: cards,
    );
  }

  Widget _metric(String label, String value, String scope) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(color: ResqColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              scope,
              style: const TextStyle(color: ResqColors.signal, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(label, style: const TextStyle(color: ResqColors.muted)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _muted(String value) {
    return Text(value, style: const TextStyle(color: ResqColors.muted));
  }

  Widget _emptyPanel(String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(value, style: const TextStyle(color: ResqColors.muted)),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> values,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final item in values)
            DropdownMenuItem(value: item, child: Text(item)),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }

  Widget _buttonRow(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: children),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback onPressed) {
    return SizedBox(
      width: 168,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _eventTile(ExperimentEvent event) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        title: Text(
          event.eventType,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          [
            _time(event.eventTimestampMs ?? event.timestampMs),
            if (event.senderCrc != null) 'sender=${_hexCrc(event.senderCrc)}',
            if (event.hopCount != null) 'hop=${event.hopCount}',
            if (event.rssi != null) 'rssi=${event.rssi}',
            if (event.payloadHash != null) event.payloadHash!,
          ].join('  '),
        ),
      ),
    );
  }

  List<Widget> _statsRows(NumericStats stats, {String suffix = ''}) {
    return [
      _kv('Sample Count', stats.count.toString()),
      _kv('Min', stats.min == null ? 'N/A' : '${stats.min}$suffix'),
      _kv(
        'Mean',
        stats.mean == null ? 'N/A' : '${stats.mean!.toStringAsFixed(2)}$suffix',
      ),
      _kv(
        'Median',
        stats.median == null
            ? 'N/A'
            : '${stats.median!.toStringAsFixed(2)}$suffix',
      ),
      _kv('Max', stats.max == null ? 'N/A' : '${stats.max}$suffix'),
    ];
  }

  String _statMs(NumericStats stats) {
    if (stats.median == null) return 'N/A';
    return '${stats.median!.toStringAsFixed(0)} ms';
  }

  String _percent(double? value) {
    return value == null ? 'N/A' : '${value.toStringAsFixed(2)} %';
  }

  String _elapsedLabel(int? startedAt) {
    if (startedAt == null) return '-';
    final elapsed = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - startedAt,
    );
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${elapsed.inHours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }

  String _time(int timestampMs) {
    return DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String();
  }

  String _hexCrc(int? crc) {
    if (crc == null) return '-';
    return crc.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String _nativeManufacturerLabel() {
    final id = _capabilities['nativeManufacturerId'];
    if (id is! int) return '-';
    return '0x${id.toRadixString(16).toUpperCase()}';
  }

  bool _manufacturerMatch() {
    return _capabilities['nativeManufacturerId'] == MeshConfig.manufacturerId;
  }

  String _permissionBlockedLabel() {
    final value = _capabilities['nativeInboxPermissionBlockedAt'];
    final timestamp = value is int ? value : int.tryParse('$value');
    if (timestamp == null || timestamp <= 0) return 'No';
    return _time(timestamp);
  }
}
