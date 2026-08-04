import 'package:flutter/services.dart';

class BackgroundServiceManager {
  static const platform = MethodChannel('com.example.pkmproject/mesh');

  static Future<void> startBackgroundService() async {
    try {
      final result = await platform.invokeMethod('startBackgroundService');
      print('[BackgroundServiceManager] Service started: $result');
    } catch (e) {
      print('[BackgroundServiceManager] Error starting service: $e');
    }
  }

  static Future<void> stopBackgroundService() async {
    try {
      final result = await platform.invokeMethod('stopBackgroundService');
      print('[BackgroundServiceManager] Service stopped: $result');
    } catch (e) {
      print('[BackgroundServiceManager] Error stopping service: $e');
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      final result = await platform.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
      print(
        '[BackgroundServiceManager] Battery optimization requested: $result',
      );
      return result ?? false;
    } catch (e) {
      print(
        '[BackgroundServiceManager] Error requesting battery optimization: $e',
      );
      return false;
    }
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result = await platform.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return result ?? false;
    } catch (e) {
      print(
        '[BackgroundServiceManager] Error reading battery optimization state: $e',
      );
      return false;
    }
  }

  static Future<void> requestSchedulerTick() async {
    try {
      await platform.invokeMethod('requestSchedulerTick');
    } catch (e) {
      print('[BackgroundServiceManager] Error requesting scheduler tick: $e');
    }
  }
}
