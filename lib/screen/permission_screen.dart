import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen>
    with WidgetsBindingObserver {
  bool _isChecking = false;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionsAndNavigate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _checkPermissionsAndNavigate();
    }
  }

  Future<void> _checkPermissionsAndNavigate() async {
    if (_hasNavigated) return;

    setState(() => _isChecking = true);
    try {
      final allGranted = await _areAllPermissionsGranted();
      if (allGranted && mounted && !_hasNavigated) {
        await _completePermissionFlow(showSuccess: false);
      }
    } catch (e) {
      debugPrint("Error checking permissions: $e");
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<bool> _areAllPermissionsGranted() async {
    return AndroidPermissionService.areCriticalPermissionsGranted();
  }

  Future<void> _requestPermissions() async {
    if (_isChecking || _hasNavigated) return;

    setState(() => _isChecking = true);

    try {
      final statuses =
          await AndroidPermissionService.requestCriticalPermissions();
      final needToOpenSettings = statuses.values.any(
        (status) => status.isPermanentlyDenied,
      );

      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      final allGranted = await _areAllPermissionsGranted();
      if (allGranted) {
        await _completePermissionFlow(showSuccess: true);
      } else if (needToOpenSettings) {
        if (mounted) _showSettingsDialog();
      } else if (mounted) {
        ResqFeedback.warning(
          context,
          'Izin belum lengkap. Aktifkan lokasi, Bluetooth, dan notifikasi.',
        );
      }
    } catch (e) {
      debugPrint("Error requesting permissions: $e");
      if (mounted) {
        ResqFeedback.error(
          context,
          'Gagal meminta izin. Coba lagi atau buka Settings aplikasi.',
        );
      }
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _completePermissionFlow({required bool showSuccess}) async {
    if (!mounted || _hasNavigated) return;
    _hasNavigated = true;

    if (showSuccess) {
      ResqFeedback.success(
        context,
        'Izin darurat aktif. ResQMesh siap memantau sinyal sekitar.',
      );
    }

    try {
      await NativeBridgeService.setRelayModeEnabled(true);
      await BackgroundServiceManager.startBackgroundService();
      await BackgroundServiceManager.requestIgnoreBatteryOptimizations();
      await NativeBridgeService.resumePendingNativeBleInbox();
      await BackgroundServiceManager.requestSchedulerTick();
    } catch (e) {
      debugPrint("Error starting rescue services after permission grant: $e");
      if (mounted) {
        ResqFeedback.warning(
          context,
          'Izin berhasil, tapi layanan latar belakang perlu dicoba lagi.',
        );
      }
    }

    if (!mounted) return;
    await Future<void>.delayed(Duration(milliseconds: showSuccess ? 700 : 0));
    if (mounted) Navigator.pushReplacementNamed(context, '/onboarding');
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ResqColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: const Text(
          'Izin Diblokir',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Android tidak lagi menampilkan dialog izin. Buka Settings aplikasi lalu aktifkan Location, Bluetooth, dan Notifications.',
          style: TextStyle(color: ResqColors.field, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Nanti',
              style: TextStyle(color: ResqColors.muted),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              openAppSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ResqColors.ember,
              foregroundColor: Colors.white,
            ),
            child: const Text('Buka Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResqColors.ink,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF211712), ResqColors.ink, Color(0xFF10171B)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    MediaQuery.of(context).size.height -
                    MediaQuery.of(context).padding.top -
                    MediaQuery.of(context).padding.bottom -
                    48,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ResqSectionHeader(
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Aktifkan Mode Darurat',
                    subtitle:
                        'ResQMesh membutuhkan izin ini agar ponsel bisa menjadi node penyelamat meski internet tidak tersedia.',
                    color: ResqColors.ember,
                  ),
                  const SizedBox(height: 28),
                  _buildReadinessPanel(),
                  const SizedBox(height: 18),
                  _buildPermissionItem(
                    Icons.location_on,
                    'Lokasi presisi',
                    'Untuk menandai posisi SOS dan membantu pemetaan korban.',
                    ResqColors.danger,
                  ),
                  const SizedBox(height: 10),
                  _buildPermissionItem(
                    Icons.bluetooth_searching,
                    'Bluetooth scan dan broadcast',
                    'Untuk menerima dan meneruskan SOS antar ponsel tanpa pairing.',
                    ResqColors.signal,
                  ),
                  const SizedBox(height: 10),
                  _buildPermissionItem(
                    Icons.notifications_active,
                    'Notifikasi layanan',
                    'Agar layanan background tetap terlihat dan tidak mudah dihentikan.',
                    ResqColors.safe,
                  ),
                  const SizedBox(height: 10),
                  _buildPermissionItem(
                    Icons.battery_alert,
                    'Optimasi baterai',
                    'Opsional, tapi sangat disarankan agar relay tetap hidup saat layar mati.',
                    ResqColors.ember,
                  ),
                  const SizedBox(height: 28),
                  ElevatedButton.icon(
                    onPressed: _isChecking ? null : _requestPermissions,
                    icon: _isChecking
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          )
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(
                      _isChecking ? 'MEMERIKSA IZIN...' : 'Izinkan & Aktifkan',
                      style: const TextStyle(fontSize: 16),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ResqColors.ember,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Jika salah satu izin ditolak, ResQMesh masih bisa dibuka tetapi relay darurat tidak akan optimal.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ResqColors.muted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadinessPanel() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ResqColors.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ResqColors.line),
      ),
      child: const Row(
        children: [
          Icon(Icons.shield_outlined, color: ResqColors.safe, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Izin diberikan sekali di awal. Setelah itu ponsel dapat scan, relay, dan sinkronisasi otomatis saat jaringan kembali.',
              style: TextStyle(
                color: ResqColors.field,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionItem(
    IconData icon,
    String title,
    String description,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ResqColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: ResqColors.muted,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
