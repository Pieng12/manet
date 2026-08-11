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
  ExperimentMetrics? _metrics;
  List<ExperimentEvent> _events = const [];
  Map<String, dynamic> _capabilities = const {};
  int _queueSize = 0;
  int _sosQueueSize = 0;
  int _ackQueueSize = 0;
  int? _earliestNextEligibleAt;
  bool _pendingRelayWork = false;
  String _eventFilter = 'ALL';
  bool _loading = true;

  final _sessionNameController = TextEditingController(text: 'CEF-H3');
  final _targetHopController = TextEditingController(text: '3');
  final _topologyController = TextEditingController(
    text: 'Android -> Relay -> Destination',
  );
  final _scenarioController = TextEditingController(text: 'HOP-3');
  final _notesController = TextEditingController();
  final _trialNotesController = TextEditingController();
  String _forwardingMode = MeshConfig.forwardingMode.logValue;
  String _nodeRole = 'RELAY';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
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
    super.dispose();
  }

  Future<void> _refresh() async {
    final session = await _researchService.currentSession();
    final trial = session == null
        ? null
        : await _researchService.currentTrial(sessionId: session.sessionId);
    final events = await _logger.events(
      sessionId: session?.sessionId,
      trialId: trial?.trialId,
      limit: 200,
    );
    final metrics = session == null
        ? null
        : await _metricsService.loadMetrics(
            sessionId: session.sessionId,
            trialId: trial?.trialId,
          );
    final capabilities = await NativeBridgeService.getBleCapabilities();
    final queueSize = await _relayQueue.queueSize();
    final sosQueueSize = await _relayQueue.queueSizeByType('sos');
    final ackQueueSize = await _relayQueue.queueSizeByType('ack');
    final earliest = await _relayQueue.earliestNextEligibleAt();
    final pendingRelayWork = await NativeBridgeService.hasPendingRelayWork();
    if (!mounted) return;
    setState(() {
      _session = session;
      _trial = trial;
      _events = events;
      _metrics = metrics;
      _capabilities = capabilities;
      _queueSize = queueSize;
      _sosQueueSize = sosQueueSize;
      _ackQueueSize = ackQueueSize;
      _earliestNextEligibleAt = earliest;
      _pendingRelayWork = pendingRelayWork;
      _loading = false;
    });
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
              ],
            ),
    );
  }

  Widget _buildLiveTab() {
    final latestPacket = _latestPacketEvent();
    return _scroll(
      children: [
        _section('Experiment Session', [
          _kv('Session', _session?.name ?? 'No active session'),
          _kv('Trial', _trial?.trialCode ?? 'No active trial'),
          _kv('Trial Status', _trial?.status ?? '-'),
          _kv('Forwarding Mode', _session?.forwardingMode ?? _forwardingMode),
          _kv('Node Role', _session?.nodeRole ?? _nodeRole),
          _kv('Hop Target', _session?.targetHop?.toString() ?? '-'),
          _kv(
            'Elapsed Time',
            _elapsedLabel(_trial?.startedAt ?? _session?.startedAt),
          ),
        ]),
        _section('Current Packet', [
          if (latestPacket == null)
            _muted('No current packet')
          else ...[
            _kv('Sender CRC', _hexCrc(latestPacket.senderCrc)),
            _kv('Protocol Time', latestPacket.timestampMs.toString()),
            _kv('Status', _detail(latestPacket, 'status') ?? '-'),
            _kv('Packet Type', _detail(latestPacket, 'kind') ?? '-'),
            _kv('Hop In', latestPacket.hopCount?.toString() ?? '-'),
            _kv('Hop Out', _detail(latestPacket, 'hop_out') ?? '-'),
            _kv(
              'RSSI',
              latestPacket.rssi == null ? '-' : '${latestPacket.rssi} dBm',
            ),
            _kv('From Server', _detail(latestPacket, 'from_server') ?? '-'),
            _kv('Payload Identity', latestPacket.payloadHash ?? '-'),
            _kv(
              'Received At',
              _time(latestPacket.eventTimestampMs ?? latestPacket.timestampMs),
            ),
          ],
        ]),
        _systemSummary(),
      ],
    );
  }

  Widget _buildMetricsTab() {
    final metrics = _metrics;
    if (metrics == null) {
      return _scroll(
        children: [
          _emptyPanel('Start a research session to calculate metrics.'),
        ],
      );
    }
    return _scroll(
      children: [
        _metricGrid([
          _metric('DSR', _percent(metrics.dsrPercent), 'CURRENT SESSION'),
          _metric(
            'RX -> Relay Start',
            _statMs(metrics.localRelayLatencyMs),
            'LOCAL DEVICE',
          ),
          _metric(
            'Duplicate Ratio',
            _percent(metrics.duplicateRatioPercent),
            'LOCAL DEVICE',
          ),
          _metric(
            'TX Success',
            metrics.txSuccessCount.toString(),
            'LOCAL DEVICE',
          ),
          _metric(
            'E2E Latency',
            metrics.e2eRequiresPeerLog
                ? 'Requires peer log'
                : _statMs(metrics.e2eLatencyMs),
            'REQUIRES PEER LOG',
          ),
          _metric(
            'TX Overhead',
            metrics.transmissionOverhead?.toStringAsFixed(2) ?? 'N/A',
            'SESSION',
          ),
        ]),
        _section('Packet Counts', [
          _kv('Unique Accepted', metrics.acceptedCount.toString()),
          _kv('Duplicate Received', metrics.duplicateCount.toString()),
          _kv('Stale Received', metrics.staleCount.toString()),
          _kv('Invalid Received', metrics.invalidCount.toString()),
          _kv('ACK Suppressed', metrics.ackSuppressedCount.toString()),
        ]),
        _section('RSSI', _statsRows(metrics.rssiStats, suffix: ' dBm')),
        _section('Hop Metrics', [
          _kv('Max Hop Observed', metrics.hopStats.max?.toString() ?? 'N/A'),
          _kv('Mean Hop', metrics.hopStats.mean?.toStringAsFixed(2) ?? 'N/A'),
          if (metrics.latestHopValidation == null)
            _kv('Hop Validation', 'N/A')
          else
            _kv(
              'Hop Validation',
              metrics.latestHopValidation!.passed
                  ? 'PASS'
                  : 'FAIL expected ${metrics.latestHopValidation!.expectedHopOut} actual ${metrics.latestHopValidation!.hopOut}',
            ),
        ]),
        _section('ACK Metrics', [
          _kv('ACK Received', metrics.ackReceivedCount.toString()),
          _kv('ACK Accepted', metrics.ackAcceptedCount.toString()),
          _kv('ACK Duplicate', metrics.ackDuplicateCount.toString()),
          _kv('ACK Stale', metrics.ackStaleCount.toString()),
          _kv('ACK Invalid', metrics.ackInvalidCount.toString()),
          _kv(
            'ACK Termination Latency',
            _statMs(metrics.ackTerminationLatencyMs),
          ),
        ]),
        _section('Transmission', [
          _kv('TX Attempt Count', metrics.txAttemptCount.toString()),
          _kv('TX Success Count', metrics.txSuccessCount.toString()),
          _kv('Relay Slot Count', metrics.relaySlotCount.toString()),
        ]),
      ],
    );
  }

  Widget _buildTrialTab() {
    return _scroll(
      children: [
        _section('Experiment Configuration', [
          _textField(_sessionNameController, 'Experiment Name'),
          _dropdown(
            label: 'Forwarding Mode',
            value: _forwardingMode,
            values: const ['controlled_epidemic', 'basic_flooding'],
            onChanged: (value) => setState(() => _forwardingMode = value),
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
          _textField(_notesController, 'Notes', maxLines: 3),
          _buttonRow([
            _action('START SESSION', Icons.play_arrow, _startSession),
            _action('END SESSION', Icons.stop, _endSession),
          ]),
        ]),
        _section('Trial Controls', [
          _kv('Current Trial', _trial?.trialCode ?? '-'),
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
          _kv('Payload Length', '${MeshConfig.protocolLength} bytes'),
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
      _kv('Forwarding Mode', MeshConfig.forwardingMode.logValue),
      _kv('Last Native Error', '${_capabilities['lastErrorCode'] ?? '-'}'),
      _kv('Permission Blocked', _permissionBlockedLabel()),
      _kv('Headless Worker', 'unknown'),
    ]);
  }

  Future<void> _startSession() async {
    final targetHop = int.tryParse(_targetHopController.text.trim()) ?? 0;
    await _researchService.startSession(
      deviceId: _syncService.deviceId,
      name: _sessionNameController.text,
      nodeRole: _nodeRole,
      targetHop: targetHop,
      topologyLabel: _topologyController.text,
      scenarioLabel: _scenarioController.text,
      notes: _notesController.text,
      forwardingMode: _forwardingMode,
    );
    await _logger.logEvent(
      eventType: 'RESEARCH_SESSION_STARTED',
      deviceId: _syncService.deviceId,
      detail: {'node_role': _nodeRole, 'target_hop': targetHop},
    );
    await _refresh();
  }

  Future<void> _endSession() async {
    final session = _session;
    if (session == null) return;
    await _researchService.endSession(session.sessionId);
    await _refresh();
  }

  Future<void> _startTrial() async {
    final session = _session;
    if (session == null) {
      await _startSession();
    }
    final activeSession = await _researchService.currentSession();
    if (activeSession == null) return;
    await _researchService.startTrial(
      sessionId: activeSession.sessionId,
      trialCodePrefix: activeSession.name,
      notes: _trialNotesController.text,
    );
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
      failureReason: result == 'FAILED' ? 'OTHER' : null,
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
    if (_trial != null) {
      await _researchService.finishTrial(
        _trial!.trialId,
        result: 'SUCCESS',
        notes: _trialNotesController.text,
      );
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

  ExperimentEvent? _latestPacketEvent() {
    for (final event in _events.reversed) {
      if (event.eventType == ExperimentEventTypes.blePacketReceived ||
          event.eventType == ExperimentEventTypes.blePacketStored ||
          event.eventType == ExperimentEventTypes.bleRelayQueued ||
          event.eventType == ExperimentEventTypes.bleRelayStarted) {
        return event;
      }
    }
    return null;
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

  String? _detail(ExperimentEvent event, String key) {
    final raw = event.detailJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded[key]?.toString();
    } catch (_) {}
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
