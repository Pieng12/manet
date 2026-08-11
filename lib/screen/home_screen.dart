import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/location_service.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/workmanager_service.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:pkmproject/widgets/improved_dialogs.dart';
import 'package:pkmproject/widgets/logs_tab.dart';
import 'package:pkmproject/widgets/map_tab.dart';
import 'package:pkmproject/widgets/messages_tab.dart';
import 'package:pkmproject/widgets/resq_ui.dart';
import 'package:pkmproject/widgets/service_status_bar.dart';
import 'package:uuid/uuid.dart' as uuid_package;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final SyncService _syncService = SyncService();
  final BleRelayService _bleRelayService = BleRelayService();
  final BleAdvertiserService _bleAdvertiserService = BleAdvertiserService();
  final List<String> _logs = ['[${DateTime.now().toIso8601String()}] Ready.'];

  late TabController _tabController;
  late List<Widget> _tabs;
  StreamSubscription<bool>? _bleAdvertisingSub;
  StreamSubscription<String>? _relayLogSub;
  Timer? _statusTimer;

  bool _isSending = false;
  bool _isBleAdvertisingRunning = false;
  bool _isBleScanningRunning = false;
  String _currentDeviceId = "Loading...";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabs = [
      MessagesTab(
        messageStream: _dbHelper.messageStream,
        onShowActiveSOSDialog: _showActiveSOSDialog,
        onDeleteMessage: _deleteMessage,
        deviceId: _syncService.deviceId,
      ),
      MapTab(messageStream: _dbHelper.messageStream),
      LogsTab(logs: _logs, onClearLogs: _clearLogs),
    ];

    _isBleAdvertisingRunning = _bleAdvertiserService.isAdvertising;
    _isBleScanningRunning = NativeBridgeService.isBleWakeUpScanning;
    _currentDeviceId = _syncService.deviceId;

    _bleAdvertisingSub = _bleAdvertiserService.onAdvertisingChanged.listen((
      isRunning,
    ) {
      if (mounted) {
        setState(() => _isBleAdvertisingRunning = isRunning);
      }
    });
    _relayLogSub = _bleRelayService.logStream.listen(_log);
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        setState(() {
          _isBleScanningRunning = NativeBridgeService.isBleWakeUpScanning;
        });
      }
    });

    _dbHelper.initialize().catchError((e) {
      _log('Database init error: $e');
    });
    BackgroundServiceManager.startBackgroundService()
        .then((_) {
          return BackgroundServiceManager.requestSchedulerTick();
        })
        .catchError((e) {
          _log('BLE relay command error: $e');
        });
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
      _logs.add('[${DateTime.now().toIso8601String()}] Log cleared.');
    });
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String();
    if (mounted) {
      setState(() {
        _logs.insert(0, '[$timestamp] $message');
        if (_logs.length > 200) _logs.removeLast();
      });
    }
  }

  Future<void> _sendSos({SOSMessage? existingSOS}) async {
    if (_isSending) return;
    setState(() => _isSending = true);

    try {
      final position = await LocationService.getCurrentPosition();
      final deviceId = _syncService.deviceId;
      final now = DateTime.now().millisecondsSinceEpoch;

      final sosMessage =
          existingSOS ??
          SOSMessage(
            id: uuid_package.Uuid().v4(),
            senderId: deviceId,
            senderCrc: crc32(deviceId),
            content: 'SOS',
            latitude: position.latitude,
            longitude: position.longitude,
            createdAt: now,
            updatedAt: now,
            status: SOSMessageStatus.active,
            isSynced: 0,
          );

      sosMessage.senderCrc ??= crc32(sosMessage.senderId);
      sosMessage.latitude = position.latitude;
      sosMessage.longitude = position.longitude;
      sosMessage.updatedAt = now;
      sosMessage.status = SOSMessageStatus.active;
      sosMessage.isSynced = 0;

      await ExperimentLogger().logEvent(
        eventType: ExperimentEventTypes.sosCreated,
        deviceId: deviceId,
        messageId: sosMessage.id,
        senderCrc: sosMessage.senderCrc,
        hopCount: sosMessage.hopCount,
        detail: {'source': existingSOS == null ? 'new' : 'replace'},
      );
      await _bleRelayService.activateForMessage(sosMessage);
      _log('SOS saved and BLE connectionless broadcast started.');
      if (mounted) {
        ResqFeedback.success(
          context,
          'SOS aktif. Broadcast BLE connectionless sedang berjalan.',
        );
      }
    } catch (e) {
      _log('Failed to send SOS: $e');
      if (mounted) {
        ResqFeedback.error(
          context,
          'Gagal mengirim SOS. Periksa lokasi, Bluetooth, dan izin aplikasi.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _cancelSOS(SOSMessage activeSOS) async {
    if (_isSending) return;
    setState(() => _isSending = true);

    try {
      activeSOS.senderCrc ??= crc32(activeSOS.senderId);
      activeSOS.status = SOSMessageStatus.cancelled;
      activeSOS.updatedAt = DateTime.now().millisecondsSinceEpoch;
      activeSOS.isSynced = 0;

      await _bleRelayService.activateForMessage(activeSOS);
      await WorkManagerService.registerSyncTask();
      await _syncService.initiateFullSync();
      _log('SOS cancellation broadcast via BLE.');
      if (mounted) {
        ResqFeedback.warning(
          context,
          'SOS dibatalkan dan status pembatalan sedang disiarkan.',
        );
      }
    } catch (e) {
      _log('Error cancelling SOS: $e');
      if (mounted) {
        ResqFeedback.error(context, 'Gagal membatalkan SOS. Coba lagi.');
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deleteMessage(SOSMessage message) async {
    final confirmed = await ImprovedDialogs.showDeleteConfirmDialog(
      context,
      message,
    );
    if (confirmed != true) return;

    final deleted = await _dbHelper.deleteMessage(
      message.id,
      _syncService.deviceId,
    );
    _log(
      deleted
          ? 'Message deleted locally: ${message.id}'
          : 'Cannot delete active own SOS.',
    );
    if (!mounted) return;
    if (deleted) {
      ResqFeedback.info(context, 'Pesan dihapus dari perangkat ini.');
    } else {
      ResqFeedback.warning(
        context,
        'SOS aktif milik sendiri tidak bisa dihapus.',
      );
    }
  }

  void _showActiveSOSDialog(SOSMessage activeSOS) {
    ImprovedDialogs.showActiveSOSDialog(
      context,
      onCancel: () => _cancelSOS(activeSOS),
      onReplace: () => _sendSos(existingSOS: activeSOS),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _bleAdvertisingSub?.cancel();
    _relayLogSub?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAnyBleRunning = _isBleScanningRunning || _isBleAdvertisingRunning;

    return Scaffold(
      backgroundColor: ResqColors.ink,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ResQMesh',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
            Text(
              _currentDeviceId.length > 20
                  ? '${_currentDeviceId.substring(0, 20)}...'
                  : _currentDeviceId,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        backgroundColor: ResqColors.surface,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              isAnyBleRunning
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: isAnyBleRunning ? Colors.green : Colors.grey,
            ),
            tooltip: isAnyBleRunning
                ? 'BLE Relay Running'
                : 'BLE Relay Stopped',
            onPressed: _toggleBleRelay,
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            tooltip: 'Manual Internet Sync',
            onPressed: () async {
              if (SyncService.offlineOnly) {
                _log('Offline-only mode active. Manual gateway sync skipped.');
                if (context.mounted) {
                  ResqFeedback.info(
                    context,
                    'Mode offline aktif. Tes BLE tidak memakai server.',
                  );
                }
                return;
              }

              _log('Manual gateway sync started...');
              try {
                await _syncService.initiateFullSync();
                _log('Manual gateway sync complete.');
                if (context.mounted) {
                  ResqFeedback.success(context, 'Sinkronisasi manual selesai.');
                }
              } catch (e) {
                _log('Manual gateway sync failed: $e');
                if (context.mounted) {
                  ResqFeedback.error(
                    context,
                    'Sinkronisasi gagal. Data tetap tersimpan lokal.',
                  );
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.analytics),
            tooltip: 'BLE Monitor',
            onPressed: () => Navigator.pushNamed(context, '/message_log'),
          ),
          IconButton(
            icon: const Icon(Icons.science_outlined),
            tooltip: 'Research Monitor',
            onPressed: () => Navigator.pushNamed(context, '/research-monitor'),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: ResqColors.ember,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey.shade400,
          tabs: const [
            Tab(icon: Icon(Icons.message), text: 'Messages'),
            Tab(icon: Icon(Icons.map), text: 'Map'),
            Tab(icon: Icon(Icons.info_outline), text: 'Logs'),
          ],
        ),
      ),
      body: Column(
        children: [
          ServiceStatusBar(
            isBleScanning: _isBleScanningRunning,
            isBleAdvertising: _isBleAdvertisingRunning,
            isSyncingEnabled: !SyncService.offlineOnly,
            onToggle: _toggleBleRelay,
          ),
          Expanded(
            child: TabBarView(controller: _tabController, children: _tabs),
          ),
          _buildSOSButton(),
        ],
      ),
    );
  }

  Future<void> _toggleBleRelay() async {
    try {
      if (_isBleScanningRunning || _isBleAdvertisingRunning) {
        await NativeBridgeService.setRelayModeEnabled(false);
        await NativeBridgeService.stopBleWakeUpScan();
        await BackgroundServiceManager.stopBackgroundService();
        _log('BLE relay stopped.');
        if (mounted) ResqFeedback.info(context, 'Relay BLE dihentikan.');
      } else {
        await NativeBridgeService.setRelayModeEnabled(true);
        await BackgroundServiceManager.startBackgroundService();
        await BackgroundServiceManager.requestSchedulerTick();
        _log('BLE relay started.');
        if (mounted) {
          ResqFeedback.success(context, 'Relay BLE aktif memantau sekitar.');
        }
      }
    } catch (e) {
      _log('BLE relay toggle failed: $e');
      if (mounted) {
        ResqFeedback.error(
          context,
          'Gagal mengubah status relay. Periksa Bluetooth dan izin.',
        );
      }
    }
    if (mounted) {
      setState(() {
        _isBleScanningRunning = NativeBridgeService.isBleWakeUpScanning;
        _isBleAdvertisingRunning = _bleAdvertiserService.isAdvertising;
      });
    }
  }

  Widget _buildSOSButton() {
    return StreamBuilder<List<SOSMessage>>(
      stream: _dbHelper.messageStream,
      builder: (context, snapshot) {
        final messages = snapshot.data ?? [];
        SOSMessage? activeSOS;
        for (final message in messages) {
          if (message.senderId == _syncService.deviceId &&
              message.status == SOSMessageStatus.active) {
            activeSOS = message;
            break;
          }
        }

        final isSOSActive = activeSOS != null;
        final baseColor = isSOSActive ? ResqColors.ember : ResqColors.danger;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ResqColors.surface,
            border: Border(top: BorderSide(color: ResqColors.line, width: 1)),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: baseColor.withValues(alpha: 0.28),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _isSending
                    ? null
                    : () {
                        if (isSOSActive && activeSOS != null) {
                          _showActiveSOSDialog(activeSOS);
                        } else {
                          _sendSos();
                        }
                      },
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(
                      colors: [
                        baseColor,
                        Color.alphaBlend(
                          Colors.black.withValues(alpha: 0.16),
                          baseColor,
                        ),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 20,
                    horizontal: 24,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isSending)
                        const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      else
                        Icon(
                          isSOSActive
                              ? Icons.warning_amber_rounded
                              : Icons.sos_outlined,
                          size: 34,
                          color: Colors.white,
                        ),
                      const SizedBox(width: 12),
                      Text(
                        _isSending
                            ? 'PROCESSING...'
                            : (isSOSActive ? 'MANAGE ACTIVE SOS' : 'SEND SOS'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.4,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
