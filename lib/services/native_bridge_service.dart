import 'package:flutter/services.dart';
import 'package:pkmproject/config/mesh_config.dart';

class NativeBridgeService {
  static const MethodChannel _platform = MethodChannel(
    'com.example.pkmproject/mesh',
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
}
