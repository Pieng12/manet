import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_export_service.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:pkmproject/widgets/resq_ui.dart';
import 'package:pkmproject/widgets/sos_map_view.dart';
import 'package:pkmproject/widgets/sos_message_card.dart';
import 'package:uuid/uuid.dart' as uuid_package;

class MeshMonitorScreen extends StatefulWidget {
  const MeshMonitorScreen({super.key});

  @override
  State<MeshMonitorScreen> createState() => _MeshMonitorScreenState();
}

class _MeshMonitorScreenState extends State<MeshMonitorScreen>
    with SingleTickerProviderStateMixin {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final SyncService _syncService = SyncService();
  final BleRelayService _bleRelayService = BleRelayService();
  final BleAdvertiserService _bleAdvertiserService = BleAdvertiserService();
  final RelayQueueService _relayQueueService = RelayQueueService();
  final ExperimentLogger _experimentLogger = ExperimentLogger();
  final List<String> _logs = [];

  late TabController _tabController;
  StreamSubscription<String>? _logSubscription;
  StreamSubscription<bool>? _advertisingSubscription;
  StreamSubscription<List<SOSMessage>>? _messageSubscription;
  Timer? _statusTimer;

  List<SOSMessage> _messages = [];
  String _messageFilter = 'all';
  String _experimentSessionId = '-';
  int _experimentEventCount = 0;
  int _relayQueueSize = 0;
  int _sosQueueSize = 0;
  int _ackQueueSize = 0;
  int? _earliestNextEligibleAt;
  Map<String, dynamic> _bleCapabilities = const {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadMessages();
    _loadExperimentStatus();
    _messageSubscription = _dbHelper.messageStream.listen((messages) {
      if (mounted) setState(() => _messages = messages);
    });
    _logSubscription = _bleRelayService.logStream.listen((message) {
      if (!mounted) return;
      setState(() {
        _logs.insert(0, '[${DateTime.now().toIso8601String()}] $message');
        if (_logs.length > 200) _logs.removeLast();
      });
    });
    _advertisingSubscription = _bleAdvertiserService.onAdvertisingChanged
        .listen((_) => mounted ? setState(() {}) : null);
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _loadExperimentStatus();
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadMessages() async {
    final messages = await _dbHelper.getAllMessages();
    if (mounted) setState(() => _messages = messages);
  }

  Future<void> _loadExperimentStatus() async {
    final session = await _experimentLogger.currentSession();
    final eventCount = await _experimentLogger.eventCount(
      sessionId: session?.sessionId,
    );
    final queueSize = await _relayQueueService.queueSize();
    final sosQueueSize = await _relayQueueService.queueSizeByType('sos');
    final ackQueueSize = await _relayQueueService.queueSizeByType('ack');
    final earliestNextEligibleAt = await _relayQueueService
        .earliestNextEligibleAt();
    final bleCapabilities = await NativeBridgeService.getBleCapabilities();
    if (!mounted) return;
    setState(() {
      _experimentSessionId = session?.sessionId ?? '-';
      _experimentEventCount = eventCount;
      _relayQueueSize = queueSize;
      _sosQueueSize = sosQueueSize;
      _ackQueueSize = ackQueueSize;
      _earliestNextEligibleAt = earliestNextEligibleAt;
      _bleCapabilities = bleCapabilities;
    });
  }

  Future<void> _broadcastTestPayload() async {
    final deviceId = _syncService.deviceId;
    final now = DateTime.now().millisecondsSinceEpoch;
    final message = SOSMessage(
      id: 'ble-test-${uuid_package.Uuid().v4()}',
      senderId: deviceId,
      senderCrc: crc32(deviceId),
      senderName: 'BLE Test Node',
      content: 'BLE offline test payload',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: now,
      updatedAt: now,
      isSynced: 0,
    );

    try {
      await _bleRelayService.activateForMessage(message);
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.sosCreated,
        deviceId: deviceId,
        messageId: message.id,
        senderCrc: message.senderCrc,
        hopCount: message.hopCount,
        detail: {'source': 'monitor_test'},
      );
      await _loadMessages();
      _addLog('TEST SOS broadcast started. CRC=${message.senderCrc}');
      if (mounted) {
        ResqFeedback.success(
          context,
          'Payload test BLE sedang dibroadcast. Cek HP lain di Logs/Messages.',
        );
      }
    } catch (e) {
      _addLog('TEST SOS broadcast failed: $e');
      if (mounted) {
        ResqFeedback.error(
          context,
          'Gagal broadcast payload test. Cek izin dan Bluetooth.',
        );
      }
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[${DateTime.now().toIso8601String()}] $message');
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _logSubscription?.cancel();
    _advertisingSubscription?.cancel();
    _messageSubscription?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var filtered = _messages;
    if (_messageFilter == 'active') {
      filtered = _messages
          .where((message) => message.status == SOSMessageStatus.active)
          .toList();
    } else if (_messageFilter == 'unsynced') {
      filtered = _messages.where((message) => message.isSynced == 0).toList();
    }

    return Scaffold(
      backgroundColor: ResqColors.ink,
      appBar: AppBar(
        title: const Text(
          'Relay Monitor',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: ResqColors.surface,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: ResqColors.ember,
          tabs: const [
            Tab(icon: Icon(Icons.message), text: 'Messages'),
            Tab(icon: Icon(Icons.bluetooth), text: 'Status'),
            Tab(icon: Icon(Icons.list_alt), text: 'Logs'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMessagesTab(filtered),
          _buildStatusTab(),
          _buildLogsTab(),
        ],
      ),
    );
  }

  Widget _buildMessagesTab(List<SOSMessage> messages) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(height: 220, child: SosMapView(messages: messages)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip('All', 'all'),
                const SizedBox(width: 8),
                _filterChip('Active', 'active'),
                const SizedBox(width: 8),
                _filterChip('Unsynced', 'unsynced'),
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadMessages,
            child: messages.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 160),
                      ResqEmptyState(
                        icon: Icons.bluetooth_disabled,
                        title: 'Belum Ada Pesan BLE',
                        message:
                            'Pesan SOS dari relay sekitar akan muncul di sini.',
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      return SosMessageCard(
                        message: messages[index],
                        isOwnMessage:
                            messages[index].senderId == _syncService.deviceId,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, String value) {
    final selected = _messageFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: ResqColors.ember,
      backgroundColor: ResqColors.surfaceRaised,
      labelStyle: TextStyle(
        color: selected ? Colors.white : ResqColors.field,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
      side: BorderSide(color: selected ? ResqColors.ember : ResqColors.line),
      onSelected: (_) => setState(() => _messageFilter = value),
    );
  }

  Widget _buildStatusTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _statusCard(
          'Device ID',
          _syncService.deviceId,
          Icons.phone_android,
          ResqColors.signal,
        ),
        _statusCard(
          'BLE Scanning',
          NativeBridgeService.isBleWakeUpScanning ? 'Active' : 'Inactive',
          Icons.radar,
          NativeBridgeService.isBleWakeUpScanning
              ? ResqColors.safe
              : ResqColors.danger,
        ),
        _statusCard(
          'BLE Advertising',
          _bleAdvertiserService.isAdvertising ? 'Active' : 'Inactive',
          Icons.bluetooth_searching,
          _bleAdvertiserService.isAdvertising
              ? ResqColors.safe
              : ResqColors.danger,
        ),
        _statusCard(
          'Scheduler',
          _bleAdvertiserService.schedulerState.name,
          Icons.timer_outlined,
          ResqColors.signal,
        ),
        _statusCard(
          'Current Packet',
          _bleAdvertiserService.currentAdvertisedMessageId ?? '-',
          Icons.cell_tower,
          ResqColors.ember,
        ),
        _statusCard(
          'Gateway Sync',
          SyncService.offlineOnly ? 'Offline test mode' : 'Opportunistic',
          SyncService.offlineOnly ? Icons.cloud_off : Icons.cloud_sync,
          SyncService.offlineOnly ? ResqColors.muted : ResqColors.ember,
        ),
        _statusCard(
          'Session ID',
          _experimentSessionId,
          Icons.fingerprint,
          ResqColors.signal,
        ),
        _statusCard(
          'Relay Queue',
          'total=$_relayQueueSize sos=$_sosQueueSize ack=$_ackQueueSize',
          Icons.queue,
          ResqColors.ember,
        ),
        _statusCard(
          'Earliest Next Eligible',
          _earliestNextEligibleAt == null
              ? '-'
              : DateTime.fromMillisecondsSinceEpoch(
                  _earliestNextEligibleAt!,
                ).toIso8601String(),
          Icons.schedule,
          ResqColors.signal,
        ),
        _buildDiagnosticsCard(),
        _statusCard(
          'Experiment Events',
          _experimentEventCount.toString(),
          Icons.analytics_outlined,
          ResqColors.safe,
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: _broadcastTestPayload,
          icon: const Icon(Icons.science_outlined),
          label: const Text('Broadcast Test BLE Payload'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            await _bleRelayService.start();
            _addLog('BLE relay scan requested manually.');
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.radar),
          label: const Text('Start BLE Scan'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final jsonFile = await ExperimentExportService().exportJson(
              sessionId: _experimentSessionId == '-'
                  ? null
                  : _experimentSessionId,
            );
            final csvFile = await ExperimentExportService().exportCsv(
              sessionId: _experimentSessionId == '-'
                  ? null
                  : _experimentSessionId,
            );
            _addLog('Experiment exported: ${jsonFile.path}');
            _addLog('Experiment exported: ${csvFile.path}');
          },
          icon: const Icon(Icons.download),
          label: const Text('Export Experiment Data'),
        ),
      ],
    );
  }

  Widget _statusCard(String title, String value, IconData icon, Color color) {
    return Card(
      color: ResqColors.surfaceRaised,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(value),
      ),
    );
  }

  Widget _buildDiagnosticsCard() {
    final entries = <String, String>{
      'Android SDK': '${_bleCapabilities['sdkInt'] ?? '-'}',
      'Device':
          '${_bleCapabilities['deviceManufacturer'] ?? '-'} ${_bleCapabilities['deviceModel'] ?? ''}',
      'Bluetooth Enabled': '${_bleCapabilities['bluetoothEnabled'] ?? '-'}',
      'BLE Scanner': '${_bleCapabilities['scannerAvailable'] ?? '-'}',
      'BLE Advertiser': '${_bleCapabilities['advertiserAvailable'] ?? '-'}',
      'Multiple Adv':
          '${_bleCapabilities['multipleAdvertisementSupported'] ?? '-'}',
      'Scan Permission': '${_bleCapabilities['scanPermission'] ?? '-'}',
      'Advertise Permission':
          '${_bleCapabilities['advertisePermission'] ?? '-'}',
      'Connect Permission': '${_bleCapabilities['connectPermission'] ?? '-'}',
      'Native Scan': '${_bleCapabilities['nativeScanActive'] ?? '-'}',
      'Native Advertiser':
          '${_bleCapabilities['nativeAdvertisingStatus'] ?? '-'}',
      'Foreground Service':
          '${_bleCapabilities['foregroundServiceActive'] ?? '-'}',
      'Pending Inbox': '${_bleCapabilities['pendingNativeInbox'] ?? '-'}',
      'Relay Mode': '${_bleCapabilities['relayModeEnabled'] ?? '-'}',
      'Last Native Error': '${_bleCapabilities['lastErrorCode'] ?? '-'}',
    };
    return Card(
      color: ResqColors.surfaceRaised,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: entries.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(
                      entry.key,
                      style: const TextStyle(color: ResqColors.muted),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildLogsTab() {
    if (_logs.isEmpty) {
      return const ResqEmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Log Relay Kosong',
        message: 'Aktivitas BLE relay akan muncul saat ada sinyal atau sync.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _logs.length,
      itemBuilder: (context, index) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ResqColors.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ResqColors.line),
          ),
          child: Text(
            _logs[index],
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Colors.white70,
            ),
          ),
        );
      },
    );
  }
}
