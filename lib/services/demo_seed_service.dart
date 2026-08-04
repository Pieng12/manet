import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/database_helper.dart';

class DemoSeedService {
  static const bool isDemoMode = bool.fromEnvironment('DEMO_MODE');

  static Future<void> seedIfNeeded() async {
    if (!isDemoMode) return;

    final dbHelper = DatabaseHelper();
    final existing = await dbHelper.getAllMessages();
    final hasDemoData = existing.any((m) => m.senderId.startsWith('demo-'));
    if (hasDemoData) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final messages = [
      SOSMessage(
        id: '11111111-1111-4111-8111-111111111111',
        senderId: 'demo-survivor-alpha',
        senderName: 'Korban A - Gedung Teknik',
        content:
            'Butuh bantuan medis. Terjebak di lantai 2 dekat tangga utama.',
        latitude: -7.95278,
        longitude: 112.61478,
        status: SOSMessageStatus.active,
        createdAt: now - const Duration(minutes: 28).inMilliseconds,
        updatedAt: now - const Duration(minutes: 8).inMilliseconds,
        isSynced: 0,
      ),
      SOSMessage(
        id: '22222222-2222-4222-8222-222222222222',
        senderId: 'demo-relay-beta',
        senderName: 'Relay Node - Posko Barat',
        content:
            'Meneruskan sinyal SOS dari area padat. Koneksi internet belum tersedia.',
        latitude: -7.95321,
        longitude: 112.61602,
        status: SOSMessageStatus.active,
        createdAt: now - const Duration(minutes: 42).inMilliseconds,
        updatedAt: now - const Duration(minutes: 12).inMilliseconds,
        isSynced: 0,
      ),
      SOSMessage(
        id: '33333333-3333-4333-8333-333333333333',
        senderId: 'demo-survivor-charlie',
        senderName: 'Korban C - Lapangan Evakuasi',
        content: 'Sinyal diterima tim rescue. Status bantuan sudah ditangani.',
        latitude: -7.95184,
        longitude: 112.61392,
        status: SOSMessageStatus.resolved,
        createdAt: now - const Duration(hours: 1, minutes: 15).inMilliseconds,
        updatedAt: now - const Duration(minutes: 25).inMilliseconds,
        isSynced: 1,
        fromServer: true,
      ),
      SOSMessage(
        id: '44444444-4444-4444-8444-444444444444',
        senderId: 'demo-cancelled-delta',
        senderName: 'Korban D - Aula Selatan',
        content:
            'Permintaan dibatalkan setelah berhasil keluar dari area bahaya.',
        latitude: -7.95402,
        longitude: 112.61518,
        status: SOSMessageStatus.cancelled,
        createdAt: now - const Duration(hours: 2).inMilliseconds,
        updatedAt: now - const Duration(hours: 1, minutes: 35).inMilliseconds,
        isSynced: 1,
      ),
    ];

    for (final message in messages) {
      await dbHelper.replaceWithLatestMessage(message);
    }
  }
}
