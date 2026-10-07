import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pkmproject/config/mesh_config.dart';

class BleRuntimeState {
  final bool scanActive;
  final bool advertisingActive;
  final bool foregroundServiceActive;
  final bool bluetoothEnabled;

  const BleRuntimeState({
    required this.scanActive,
    required this.advertisingActive,
    required this.foregroundServiceActive,
    required this.bluetoothEnabled,
  });

  factory BleRuntimeState.fromCapabilities(Map<String, dynamic> capabilities) {
    return BleRuntimeState(
      scanActive: capabilities['nativeScanActive'] == true,
      advertisingActive: capabilities['nativeAdvertisingActive'] == true,
      foregroundServiceActive: capabilities['foregroundServiceActive'] == true,
      bluetoothEnabled: capabilities['bluetoothEnabled'] == true,
    );
  }

  bool get relayActuallyRunning =>
      scanActive || advertisingActive || foregroundServiceActive;

  bool get startVerified => foregroundServiceActive && scanActive;

  bool get stopVerified =>
      !scanActive && !advertisingActive && !foregroundServiceActive;

  Map<String, bool> toLogMap() => {
    'nativeScanActive': scanActive,
    'nativeAdvertisingActive': advertisingActive,
    'foregroundServiceActive': foregroundServiceActive,
    'bluetoothEnabled': bluetoothEnabled,
  };
}

class NativeBridgeService {
  static Future<bool> requestResearchCommand(Map<String, dynamic> args) async =>
      await _platform.invokeMethod<bool>('requestResearchCommand', {
        'json': jsonEncode(args),
      }) ==
      true;
  static Future<Map<String, dynamic>> setResearchParticipation(
    bool enabled, {
    required bool rxOnly,
  }) async {
    final value = await _platform.invokeMapMethod<String, dynamic>(
      'setResearchParticipation',
      {'enabled': enabled, 'rxOnly': rxOnly},
    );
    return value ?? {'ok': false, 'error': 'NO_NATIVE_CONFIRMATION'};
  }

  static Future<void> configureResearchPhyTelemetry(
    Map<String, dynamic> args,
  ) async {
    try {
      await _platform.invokeMethod('configureResearchPhyTelemetry', args);
    } catch (error) {
      debugPrint('Optional research PHY telemetry unavailable: $error');
    }
  }

  static Future<List<Map<String, dynamic>>> researchPhyEvents(
    String sessionId,
    String? trialId,
  ) async {
    try {
      final rows = await _platform.invokeMethod<List>(
        'getResearchPhyTelemetry',
        {'sessionId': sessionId, 'trialId': trialId},
      );
      return (rows ?? [])
          .map(
            (row) =>
                Map<String, dynamic>.from(jsonDecode(row as String) as Map),
          )
          .toList();
    } catch (error) {
      debugPrint('Optional research PHY export unavailable: $error');
      return [];
    }
  }

  static const MethodChannel _platform = MethodChannel(
    'id.ac.usu.resqmesh/mesh',
  );

  // Track whether native BLE wake-up scan is active
  static bool _isBleWakeUpScanning = false;
  static bool get isBleWakeUpScanning => _isBleWakeUpScanning;

  @visibleForTesting
  static void debugSetBleWakeUpScanningForTest(bool isScanning) {
    _isBleWakeUpScanning = isScanning;
  }

  static Future<bool> startBleWakeUpScan() async {
    try {
      final bool? result = await _platform.invokeMethod('startBleWakeUpScan', {
        'scanAllAdvertisements': MeshConfig.scanAllAdvertisements,
      });
      _isBleWakeUpScanning = result ?? false;
      return _isBleWakeUpScanning;
    } on PlatformException catch (e) {
      print("Failed to start BLE Wake-up Scan: '${e.message}'.");
      _isBleWakeUpScanning = false;
      return false;
    }
  }

  static Future<bool> stopBleWakeUpScan() async {
    try {
      final bool? result = await _platform.invokeMethod('stopBleWakeUpScan');
      final bool stopped = result ?? false;
      if (stopped) {
        _isBleWakeUpScanning = false;
      }
      return stopped;
    } on PlatformException catch (e) {
      print("Failed to stop BLE Wake-up Scan: '${e.message}'.");
      return false;
    }
  }

  static Future<void> setRelayModeEnabled(bool enabled) async {
    try {
      await _platform.invokeMethod('setRelayModeEnabled', {'enabled': enabled});
    } on PlatformException catch (e) {
      print("Failed to set relay mode: '${e.message}'.");
    }
  }

  static Future<void> setHasPendingRelayWork(bool hasPending) async {
    try {
      await _platform.invokeMethod('setHasPendingRelayWork', {
        'hasPending': hasPending,
      });
    } on PlatformException catch (e) {
      print("Failed to publish relay work state: '${e.message}'.");
    }
  }

  static Future<void> setResearchRxBurstGapMs(int value) async {
    if (value <= 0) throw ArgumentError.value(value, 'value');
    await _platform.invokeMethod('setResearchRxBurstGapMs', {
      'rxBurstGapMs': value,
    });
  }

  static Future<Map<String, dynamic>> configureBleRadio(String mode) async {
    final result = await _platform.invokeMethod<Map>('configureBleRadio', {
      'mode': mode,
    });
    return Map<String, dynamic>.from(result ?? {});
  }

  static Future<void> configureRangeTelemetry(String runId, int until) async {
    await _platform.invokeMethod('configureRangeTelemetry', {
      'runId': runId,
      'until': until,
    });
  }

  static Future<Map<String, dynamic>> getRangeRxTelemetry() async {
    final value = await _platform.invokeMethod<Map>('getRangeRxTelemetry');
    return Map<String, dynamic>.from(value ?? {});
  }

  static Future<void> setRangeScreenAwake(bool enabled) async {
    await _platform.invokeMethod('setRangeScreenAwake', {'enabled': enabled});
  }

  // UI-only consent request; callers must read capabilities to verify STATE_ON.
  static Future<Map<String, dynamic>> requestBluetoothEnable() async {
    final value = await _platform.invokeMethod<Map>('requestBluetoothEnable');
    return Map<String, dynamic>.from(value ?? {'state': 'failed'});
  }

  static Future<bool> hasPendingRelayWork() async {
    try {
      return await _platform.invokeMethod<bool>('hasPendingRelayWork') ?? false;
    } on PlatformException catch (e) {
      print("Failed to read relay work state: '${e.message}'.");
      return false;
    }
  }

  static Future<Map<String, dynamic>> getBleCapabilities() async {
    try {
      final result = await _platform.invokeMapMethod<String, dynamic>(
        'getBleCapabilities',
      );
      return result ?? const <String, dynamic>{};
    } on PlatformException catch (e) {
      print("Failed to read BLE capabilities: '${e.message}'.");
      return const <String, dynamic>{};
    }
  }

  static Future<BleRuntimeState> getBleRuntimeState() async {
    final state = BleRuntimeState.fromCapabilities(await getBleCapabilities());
    _isBleWakeUpScanning = state.scanActive;
    return state;
  }

  static Future<Map<String, dynamic>> getDeviceMetadata() async {
    try {
      final result = await _platform.invokeMapMethod<String, dynamic>(
        'getDeviceMetadata',
      );
      return result ?? const <String, dynamic>{};
    } on PlatformException catch (e) {
      print("Failed to read device metadata: '${e.message}'.");
      return const <String, dynamic>{};
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingBleInbox() async {
    try {
      final result = await _platform.invokeListMethod<dynamic>(
        'getPendingBleInbox',
      );
      return (result ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } on PlatformException catch (e) {
      print("Failed to read native BLE inbox: '${e.message}'.");
      return const <Map<String, dynamic>>[];
    }
  }

  static Future<void> acknowledgeBleInboxItem(String id) async {
    try {
      await _platform.invokeMethod('acknowledgeBleInboxItem', {'id': id});
    } on PlatformException catch (e) {
      print("Failed to acknowledge native BLE inbox item: '${e.message}'.");
    }
  }

  static Future<void> failBleInboxItem(String id) async {
    try {
      await _platform.invokeMethod('failBleInboxItem', {'id': id});
    } on PlatformException catch (e) {
      print("Failed to fail native BLE inbox item: '${e.message}'.");
    }
  }

  static Future<bool> resumePendingNativeBleInbox() async {
    try {
      return await _platform.invokeMethod<bool>(
            'resumePendingNativeBleInbox',
          ) ??
          false;
    } on PlatformException catch (e) {
      print("Failed to resume native BLE inbox recovery: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> clearNativeBleInboxPermissionBlocked() async {
    try {
      return await _platform.invokeMethod<bool>(
            'clearNativeBleInboxPermissionBlocked',
          ) ??
          false;
    } on PlatformException catch (e) {
      print(
        "Failed to clear native BLE inbox permission diagnostic: '${e.message}'.",
      );
      return false;
    }
  }

  static Future<void> clearNativeBleInbox() async {
    await _platform.invokeMethod('clearNativeBleInbox');
  }
}
