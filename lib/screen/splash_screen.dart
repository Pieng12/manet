import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/services/demo_seed_service.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  final _ble = FlutterReactiveBle();
  StreamSubscription<BleStatus>? _statusSubscription;
  String _statusText = 'Initializing...';
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.elasticOut),
    );
    _animationController.forward();
    _initializeApp();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _statusSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    if (DemoSeedService.isDemoMode) {
      setState(() {
        _statusText = 'Demo mode ready. Navigating...';
      });
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) Navigator.pushReplacementNamed(context, '/onboarding');
      });
      return;
    }

    // Defer the check to ensure the first frame is rendered.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final allGranted =
          await AndroidPermissionService.areCriticalPermissionsGranted();

      if (allGranted) {
        // Permissions are granted, now check BLE hardware status
        _checkBleStatus();
      } else {
        // Permissions are not granted, navigate to the permission screen
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/permission');
        }
      }
    });
  }

  void _checkBleStatus() {
    // 2. Check current BLE status immediately and then subscribe to events
    final initial = _ble.status;
    // ignore: avoid_print
    print('[Splash] initial BLE status: $initial');

    if (initial == BleStatus.ready) {
      setState(() {
        _statusText = 'Bluetooth is ready. Navigating...';
      });
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) Navigator.pushReplacementNamed(context, '/onboarding');
      });
      return;
    } else if (initial == BleStatus.poweredOff) {
      setState(() {
        _statusText = 'Please enable Bluetooth to continue.';
      });
    } else if (initial == BleStatus.unauthorized) {
      // This should have been caught by the permission check, but as a fallback...
      setState(() {
        _statusText = 'Bluetooth permissions are not granted.';
      });
      if (mounted) Navigator.pushReplacementNamed(context, '/permission');
      return;
    } else if (initial == BleStatus.unsupported) {
      setState(() {
        _statusText = 'This device does not support Bluetooth.';
      });
      return;
    } else {
      setState(() {
        _statusText = 'Waiting for Bluetooth...';
      });
    }

    // Listen to the stream to react to runtime changes.
    _statusSubscription = _ble.statusStream.listen((status) {
      if (!mounted) return;

      switch (status) {
        case BleStatus.ready:
          setState(() {
            _statusText = 'Bluetooth is ready. Navigating...';
          });
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) Navigator.pushReplacementNamed(context, '/onboarding');
          });
          _statusSubscription?.cancel();
          break;
        case BleStatus.poweredOff:
          setState(() {
            _statusText = 'Please enable Bluetooth to continue.';
          });
          break;
        case BleStatus.unauthorized:
          setState(() {
            _statusText = 'Bluetooth permissions are not granted.';
          });
          Navigator.pushReplacementNamed(context, '/permission');
          break;
        case BleStatus.unsupported:
          setState(() {
            _statusText = 'This device does not support Bluetooth.';
          });
          break;
        default:
          setState(() {
            _statusText = 'Waiting for Bluetooth...';
          });
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResqColors.ink,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF151F23), ResqColors.ink, Color(0xFF1D1511)],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 104,
                        height: 104,
                        decoration: BoxDecoration(
                          color: ResqColors.danger.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: ResqColors.danger.withValues(alpha: 0.75),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.sos_outlined,
                          size: 58,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 28),
                      const Text(
                        'ResQMesh',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Emergency mesh network for offline rescue signals',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: ResqColors.field,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 48),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 360),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: ResqColors.surfaceRaised,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ResqColors.line),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  ResqColors.ember,
                                ),
                                strokeWidth: 3,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                _statusText,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SplashBadge(
                            icon: Icons.bluetooth_searching,
                            label: 'BLE relay',
                          ),
                          _SplashBadge(
                            icon: Icons.cloud_off,
                            label: 'Offline first',
                          ),
                          _SplashBadge(
                            icon: Icons.location_on,
                            label: 'Location aware',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplashBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SplashBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ResqColors.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ResqColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: ResqColors.signal, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: ResqColors.field,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
