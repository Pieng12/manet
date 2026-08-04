import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class AndroidPermissionService {
  static const MethodChannel _platform = MethodChannel(
    'id.ac.usu.resqmesh/mesh',
  );

  static Future<int?> androidSdkInt() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    try {
      return await _platform.invokeMethod<int>('getAndroidSdkInt');
    } catch (e) {
      debugPrint('[AndroidPermissionService] SDK check failed: $e');
      return null;
    }
  }

  static Future<List<Permission>> criticalPermissions() async {
    final sdkInt = await androidSdkInt();
    if (sdkInt == null) return const <Permission>[];

    final permissions = <Permission>[Permission.location];

    if (sdkInt >= 29 && sdkInt <= 30) {
      permissions.add(Permission.locationAlways);
    }

    if (sdkInt >= 31) {
      permissions.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ]);
    }

    if (sdkInt >= 33) {
      permissions.add(Permission.notification);
    }

    return permissions;
  }

  static Future<bool> areCriticalPermissionsGranted() async {
    final permissions = await criticalPermissions();

    for (final permission in permissions) {
      final status = await permission.status;
      if (!status.isGranted && !status.isLimited) {
        debugPrint(
          '[AndroidPermissionService] NOT GRANTED: $permission ($status)',
        );
        return false;
      }
    }

    return true;
  }

  static Future<Map<Permission, PermissionStatus>>
  requestCriticalPermissions() async {
    final sdkInt = await androidSdkInt();
    final permissions = await criticalPermissions();
    if (permissions.isEmpty) return const <Permission, PermissionStatus>{};
    final foregroundPermissions = sdkInt != null && sdkInt >= 29 && sdkInt <= 30
        ? permissions
              .where((permission) => permission != Permission.locationAlways)
              .toList()
        : permissions;
    final result = <Permission, PermissionStatus>{};
    result.addAll(await foregroundPermissions.request());

    if (sdkInt != null && sdkInt >= 29 && sdkInt <= 30) {
      final foregroundGranted =
          result[Permission.location]?.isGranted == true ||
          result[Permission.location]?.isLimited == true;
      if (foregroundGranted) {
        result[Permission.locationAlways] = await Permission.locationAlways
            .request();
      }
    }
    return result;
  }
}
