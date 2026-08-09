import 'package:flutter/services.dart';
import 'package:pkmproject/config/mesh_config.dart';

class NativeBridgeService {
  static const MethodChannel _platform = MethodChannel(
    'id.ac.usu.resqmesh/mesh',
  );

  // Track whether native BLE wake-up scan is active
  static bool _isBleWakeUpScanning = false;
  static bool get isBleWakeUpScanning => _isBleWakeUpScanning;

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
}
