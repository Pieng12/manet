# ResQMesh

ResQMesh adalah aplikasi SOS offline-first untuk Android yang menyebarkan pesan
darurat melalui Bluetooth Low Energy advertising. Perangkat dapat membuat SOS,
menyimpan pesan secara lokal, melakukan relay antarperangkat tanpa pairing, dan
menjadi gateway ke server hanya saat mode gateway diaktifkan secara eksplisit.

## Status Project

Project berada pada tahap implementasi dan pengujian skripsi. Fitur inti yang
sudah tersedia:

- Payload BLE connectionless sepanjang 17 byte.
- ACK-terminated persistent epidemic forwarding.
- Hop count tersaturasi di 63, adaptive backoff, jitter, dan deduplikasi packet.
- Persistent relay queue dengan prioritas ACK.
- ACK gateway sebagai persistent anti-message.
- Native Android BLE scan/advertising dengan manufacturer filter.
- Background recovery setelah app removed, boot, dan service restart.
- Experiment session, event log, RSSI capture, dan export CSV/JSON.

## Arsitektur

```text
Flutter UI
  -> SOSMessage model dan SQLite
  -> BleRelayService
  -> ForwardingPolicy dan RelayQueueService
  -> BleAdvertiserService
  -> NativeBridgeService
  -> Android native BLE scanner/advertiser
  -> SyncService bila RESQMESH_MODE=gateway
```

Database lokal adalah sumber kebenaran untuk pesan, queue relay, ACK, dan log
eksperimen. BLE hanya membawa packet ringkas; data lengkap tetap disimpan di
perangkat dan dikirim ke server melalui gateway.

## Alur SOS

1. User membuat SOS dari aplikasi.
2. Aplikasi menyimpan `SOSMessage` ke SQLite dengan `hopCount=0` dan metadata
   relay.
3. Packet SOS 17 byte dibuat dari sender CRC, timestamp, koordinat, status, dan
   flags.
4. Native Android mengiklankan packet sebagai manufacturer data BLE.
5. Perangkat lain yang melakukan scan menerima packet, memvalidasi header,
   status, koordinat, hop, timestamp, dan identitas packet.
6. Pesan valid disimpan lokal dan masuk relay queue.

## Alur Relay

Relay memakai ACK-terminated persistent epidemic forwarding. Setiap node
menyimpan SOS aktif di persistent relay queue dan terus mengiklankan ulang
selama belum ada ACK server, belum digantikan state yang lebih baru, dan belum
dihapus secara administratif. `hopCount` tetap dikirim sebagai metrik dan
disaturasi pada 63 agar tidak overflow kembali ke 0.

Mode forwarding:

- `controlled` default: memakai dedup, fairness, adaptive backoff, cooldown, dan
  jitter.
- `basic`: pembanding eksperimen yang lebih agresif.

```bash
flutter run --dart-define=RESQMESH_FORWARDING_MODE=controlled
flutter run --dart-define=RESQMESH_FORWARDING_MODE=basic
```

## Alur Gateway dan ACK

Default aplikasi adalah mode offline. Dalam mode ini ResQMesh hanya memakai BLE
dan tidak mencoba menghubungi server.

```bash
flutter run --dart-define=RESQMESH_MODE=offline
```

Mode gateway harus diaktifkan eksplisit:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=gateway \
  --dart-define=RESQMESH_API_BASE_URL=https://example.com/api
```

Gateway hanya upload jika perangkat memiliki interface jaringan aktif dan server
lulus health check:

```text
GET /health
```

Upload membawa identitas idempotency berbasis `local_message_id`,
`sender_device_id`, `sender_crc`, dan `updated_at`.

Respons ACK server:

```json
{
  "acknowledged": true,
  "ack_data": [
    {
      "sender_crc": 12345,
      "ack_timestamp": "2026-08-04T08:00:00Z",
      "status": "RESOLVED"
    }
  ]
}
```

ACK valid disebarkan kembali lewat BLE sebagai persistent anti-message. ACK
tidak memakai hard hop limit atau TTL 2 menit, tetap diprioritaskan di queue,
dan menghentikan SOS hanya saat diterima oleh node pembawa SOS yang cocok.

## Format Payload 17 Byte

Manufacturer data memakai `MeshConfig.manufacturerId = 0xFFFF` untuk penelitian
internal. ID ini bukan ID produksi resmi.

```text
Byte 0-1   header ASCII "RM"
Byte 2-5   sender CRC32
Byte 6-8   timestamp compact 24-bit
Byte 9-11  latitude 24-bit untuk SOS, 0 untuk ACK
Byte 12-14 longitude 24-bit untuk SOS, 0 untuk ACK
Byte 15    SOSMessageStatus index
Byte 16    flags: bit 7 ACK, bit 6 fromServer, bit 0-5 hopCount
```

Payload harus tetap 17 byte kecuali protokol diubah secara terdokumentasi.

## Persyaratan Perangkat

- Android dengan BLE scanning.
- Perangkat harus mendukung BLE advertising untuk menjadi relay aktif.
- Android 12+ membutuhkan izin `BLUETOOTH_SCAN` dan `BLUETOOTH_ADVERTISE`.
- Android 6-11 umumnya membutuhkan izin lokasi untuk scan BLE.
- Background behavior bergantung pada vendor, Doze, dan battery optimization.

Daftar kompatibilitas ada di
[`docs/device_compatibility.md`](docs/device_compatibility.md).

## Cara Build

```bash
flutter pub get
dart format .
flutter analyze
flutter test
flutter build apk --debug
```

## Cara Memulai Sesi Eksperimen

Jalankan aplikasi dalam mode yang ingin diuji. Session eksperimen dibuat saat
service/app dimulai dan menyimpan konfigurasi forwarding, backoff, lifetime
legacy, dan timestamp mulai.

Panduan lengkap ada di
[`docs/experiment_protocol.md`](docs/experiment_protocol.md).

## Cara Mengekspor Data

Buka Relay Monitor, lalu gunakan tombol export experiment data. Aplikasi
menghasilkan file JSON dan CSV untuk session aktif.

## Dokumentasi Teknis

- [`DOKUMENTASI_RESQMESH_BLE.md`](DOKUMENTASI_RESQMESH_BLE.md)
- [`docs/background_recovery_test_plan.md`](docs/background_recovery_test_plan.md)
- [`docs/experiment_protocol.md`](docs/experiment_protocol.md)
- [`docs/device_compatibility.md`](docs/device_compatibility.md)
- [`docs/known_limitations.md`](docs/known_limitations.md)

## Keterbatasan

Keterbatasan utama: BLE advertising tidak menjamin delivery, background Android
tidak seragam antar vendor, payload tidak terenkripsi, CRC32 hanya identifier
ringkas, dan compatibility harus dibuktikan dengan perangkat fisik.

Daftar lengkap ada di [`docs/known_limitations.md`](docs/known_limitations.md).

## Privasi dan Keamanan

Payload BLE saat ini ringkas dan tidak terenkripsi. Jangan menaruh credential,
endpoint rahasia, atau data pribadi sensitif di payload BLE. Untuk produksi,
tambahkan autentikasi payload, enkripsi atau signature ringkas, validasi server,
dan manufacturer ID resmi.
