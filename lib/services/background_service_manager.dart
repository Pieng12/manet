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

  static Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      final result = await platform.invokeMethod(
        'requestIgnoreBatteryOptimizations',
      );
      print(
        '[BackgroundServiceManager] Battery optimization requested: $result',
      );
    } catch (e) {
      print(
        '[BackgroundServiceManager] Error requesting battery optimization: $e',
      );
    }
  }
}
