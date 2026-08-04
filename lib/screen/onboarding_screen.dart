import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndShowBackgroundSettingsDialog();
    });
  }

  Future<void> _checkAndShowBackgroundSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenDialog = prefs.getBool('has_seen_background_dialog') ?? false;
    if (hasSeenDialog || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ResqColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: const Row(
          children: [
            Icon(Icons.settings_applications, color: ResqColors.ember),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Perkuat Background',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Pada beberapa HP, aktifkan Auto Start dan Allow background activity di Settings agar relay SOS tetap hidup saat aplikasi ditutup.',
          style: TextStyle(color: ResqColors.field, fontSize: 14, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              prefs.setBool('has_seen_background_dialog', true);
              if (mounted) {
                ResqFeedback.info(
                  context,
                  'Pengaturan background bisa dibuka nanti dari Settings HP.',
                );
              }
            },
            child: const Text(
              'Nanti',
              style: TextStyle(color: ResqColors.muted),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await prefs.setBool('has_seen_background_dialog', true);
              await openAppSettings();
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

  void _navigateToHome() {
    Navigator.pushReplacementNamed(context, '/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResqColors.ink,
      appBar: AppBar(title: const Text('ResQMesh Ready')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const ResqSectionHeader(
              icon: Icons.health_and_safety_outlined,
              title: 'Node Darurat Siap',
              subtitle:
                  'Ponsel ini dapat mengirim, menerima, dan meneruskan sinyal SOS melalui mesh Bluetooth.',
              color: ResqColors.safe,
            ),
            const SizedBox(height: 20),
            _StatusPanel(
              icon: Icons.check_circle_outline,
              title: 'Izin utama aktif',
              message:
                  'Lokasi, Bluetooth, dan notifikasi sudah siap untuk mode darurat.',
              color: ResqColors.safe,
            ),
            const SizedBox(height: 12),
            _StatusPanel(
              icon: Icons.bluetooth_searching,
              title: 'Connectionless relay',
              message:
                  'SOS dikirim sebagai broadcast singkat, jadi perangkat sekitar tidak perlu pairing.',
              color: ResqColors.signal,
            ),
            const SizedBox(height: 12),
            _StatusPanel(
              icon: Icons.cloud_sync_outlined,
              title: 'Sinkron saat jaringan kembali',
              message:
                  'Pesan tersimpan lokal lebih dulu, lalu dikirim ke gateway internet ketika tersedia.',
              color: ResqColors.ember,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ResqColors.surfaceRaised,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ResqColors.line),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Saat keadaan bencana',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 10),
                  _GuidanceRow(
                    icon: Icons.sos_outlined,
                    text:
                        'Tekan SEND SOS hanya saat benar-benar butuh bantuan.',
                  ),
                  _GuidanceRow(
                    icon: Icons.my_location,
                    text: 'Biarkan lokasi aktif agar titik evakuasi akurat.',
                  ),
                  _GuidanceRow(
                    icon: Icons.battery_charging_full,
                    text: 'Hemat baterai, tapi jangan matikan Bluetooth.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _navigateToHome,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Masuk Posko ResQMesh'),
              style: ElevatedButton.styleFrom(
                backgroundColor: ResqColors.safe,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color color;

  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ResqColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: ResqColors.muted,
                    fontSize: 12,
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

class _GuidanceRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _GuidanceRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: ResqColors.ember, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
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
}
