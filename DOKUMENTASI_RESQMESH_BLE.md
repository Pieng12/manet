# Dokumentasi Teknis ResQMesh BLE

Dokumen ini menyinkronkan desain teknis ResQMesh dengan implementasi terbaru.
ResQMesh memakai BLE advertising dan BLE scanning sebagai media komunikasi
connectionless antarperangkat Android. Tidak ada pairing, koneksi GATT, Nearby
Connections, Wi-Fi Aware, atau Bluetooth Mesh resmi pada scope saat ini.

## Tujuan Sistem

- Mengirim SOS saat internet tidak tersedia.
- Menyebarkan SOS antarperangkat lewat relay BLE.
- Menjaga pesan tetap lokal sampai ACK valid diterima.
- Mengubah perangkat online menjadi gateway hanya jika mode gateway diaktifkan.
- Menghasilkan log eksperimen yang dapat diekspor dan dihitung metriknya.

## Konfigurasi Terpusat

Konfigurasi runtime utama berada di `lib/config/mesh_config.dart`.

| Konfigurasi | Nilai default | Fungsi |
| --- | --- | --- |
| `RESQMESH_MODE` | `offline` | Mode aplikasi: `offline` atau `gateway`. |
| `RESQMESH_API_BASE_URL` | backend default | Base URL API saat mode gateway. |
| `RESQMESH_FORWARDING_MODE` | `controlled` | `controlled` atau `basic`. |
| `protocolLength` | `17` | Panjang payload BLE. |
| `manufacturerId` | `0xFFFF` | Manufacturer ID penelitian internal. |
| `defaultMaxHop` | `5` | Nilai legacy/metadata, bukan cutoff relay aktif. |
| `maxAckHop` | `5` | Nilai legacy/metadata, bukan cutoff ACK aktif. |
| `defaultMessageLifetime` | `6 jam` | Nilai legacy/metadata, bukan cutoff SOS aktif. |
| `ackLifetime` | `2 menit` | Nilai legacy/metadata, bukan TTL ACK aktif. |
| `adaptiveBackoffBase` | `10 detik` | Backoff awal setelah relay sukses. |
| `adaptiveBackoffMax` | `5 menit` | Batas atas adaptive backoff. |
| `scanAllAdvertisements` | `false` | Scanner default hanya manufacturer filter. |
| `connectableAdvertising` | `false` | Advertising default non-connectable. |

`0xFFFF` adalah ID uji/reserved dan tidak boleh diklaim sebagai ID produksi
resmi.

## Modul Utama

| Modul | Peran |
| --- | --- |
| `SOSMessage` | Model pesan dengan hop, metadata legacy, relay metadata, dan sender CRC. |
| `BlePacket` | Pack/unpack payload SOS dan ACK 17 byte. |
| `BleRelayService` | Menerima packet, validasi, simpan, relay, ACK, dan logging. |
| `ForwardingPolicy` | Menentukan apakah packet boleh diteruskan. |
| `RelayQueueService` | Persistent relay queue dengan prioritas ACK dan rotasi fairness. |
| `BleAdvertiserService` | Mengiklankan SOS/ACK dan memulihkan advertising. |
| `NativeBridgeService` | Bridge Flutter ke native Android BLE/background. |
| `SyncService` | Health check, idempotent upload, dan pemrosesan ACK server. |
| `ExperimentLogger` | Session eksperimen, event log, RSSI, export CSV/JSON. |

## Native Android BLE

Komponen native Kotlin menangani scan dan advertising karena background BLE lebih
andal dikerjakan di sisi Android:

- `NativeBleAdvertiser.kt`: menjalankan non-connectable BLE advertising,
  menyisipkan payload 17 byte ke manufacturer data, dan mengembalikan status
  callback advertiser.
- `NativeBleManager.kt`: menjalankan BLE scan dengan manufacturer filter default
  dan PendingIntent.
- `BleWakeUpReceiver.kt`: menerima hasil scan, mengekstrak payload 17 byte,
  menyertakan RSSI, lalu membangunkan service.
- `MeshBackgroundService.kt`: menjaga scan/advertising dan menghubungkan event
  native ke Dart background isolate.
- `BootReceiver.kt`: memulihkan service setelah boot.
- `NativeBatteryOptimization.kt`: membuka request battery optimization exemption.

Fallback sukses palsu untuk advertising tidak digunakan. Jika native advertising
tidak tersedia atau gagal, compatibility state harus menandai perangkat tidak
kompatibel sebagai relay aktif.

## Format Payload BLE 17 Byte

Semua packet memakai panjang tetap 17 byte.

```text
Byte 0-1   header ASCII "RM"
Byte 2-5   sender CRC32 unsigned big-endian
Byte 6-8   timestamp compact 24-bit
Byte 9-11  latitude encoded 24-bit untuk SOS, 0 untuk ACK
Byte 12-14 longitude encoded 24-bit untuk SOS, 0 untuk ACK
Byte 15    SOSMessageStatus index
Byte 16    flags
```

Flags pada byte 16:

```text
bit 7      ACK flag
bit 6      fromServer flag
bit 0-5    hopCount, maksimum representasi protokol 63
```

SOS memakai ACK flag `0`. ACK memakai ACK flag `1`. Timestamp disimpan dengan
resolusi detik dan direkonstruksi terhadap waktu referensi penerima.

CRC32 hanya identifier ringkas untuk payload, bukan mekanisme keamanan.

## Alur SOS

```text
User membuat SOS
  -> SOSMessage disimpan lokal
  -> hopCount=0 dan metadata relay disiapkan
  -> BlePacket.packSos membuat payload 17 byte
  -> Native advertiser mengiklankan payload
```

Saat perangkat lain menerima payload:

```text
Native scan menerima manufacturer data
  -> payload dan RSSI dikirim ke Dart
  -> BlePacket.unpack memvalidasi header, panjang, status, dan flags
  -> forwarding policy memeriksa duplicate, koordinat, timestamp, dan hop
  -> pesan valid disimpan
  -> hopCount dinaikkan sebelum relay
  -> relay queue menjadwalkan advertising berikutnya
```

## Relay Queue dan Forwarding

Relay queue disimpan di SQLite sehingga state relay tidak hilang saat service
berhenti. Queue tidak menghapus SOS aktif karena max hop, lifetime, atau total
relay count. SOS tetap berada di queue sampai ACK server diterima, state yang
lebih baru menggantikannya, atau dilakukan administrative deletion.

Controlled persistent epidemic forwarding default memakai:

- dedup berbasis identity packet;
- fairness antar SOS;
- adaptive backoff;
- cooldown;
- jitter;
- relay count sebagai metrik saja.

Basic flooding disediakan sebagai pembanding eksperimen.

## Gateway dan ACK

Mode offline adalah default dan tidak melakukan request API. Mode gateway hanya
aktif dengan:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=gateway \
  --dart-define=RESQMESH_API_BASE_URL=https://example.com/api
```

Gateway memeriksa:

```text
GET /health
```

Upload SOS bersifat idempotent dan membawa identitas lokal. Respons ACK yang
didukung:

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

ACK diterima jika `sender_crc` cocok dan timestamp ACK tidak lebih lama dari
pesan lokal. ACK valid disimpan sebagai persistent anti-message, diprioritaskan
di queue, dideduplikasi, dan disebarkan ulang tanpa hard hop limit atau TTL 2
menit sampai node pembawa SOS menerimanya.

## Database Lokal

Skema saat ini mencakup:

- `sos_messages`: pesan lokal/relay, status sync, hop, metadata legacy, sender
  CRC, dan relay metadata.
- `relay_queue`: queue persisten untuk packet SOS dan ACK.
- `processed_packets`: dedup packet SOS/ACK.
- `gateway_acks`: ACK dari gateway dan metadata relay.
- `experiment_sessions`: konfigurasi dan waktu session eksperimen.
- `experiment_events`: event log, RSSI, hop, hash payload, dan detail JSON.

Migrasi database harus menambah kolom/tabel tanpa menghapus data lama.

## Background Recovery

ResQMesh memulihkan scan, advertising, dan queue saat:

- aplikasi berjalan foreground;
- aplikasi pindah ke background;
- app removed dari recent apps;
- perangkat reboot;
- service restart;
- user mengubah battery optimization.

Checklist pengujian ada di
[`docs/background_recovery_test_plan.md`](docs/background_recovery_test_plan.md).

## Eksperimen dan Metrik

Relay Monitor menyediakan export session eksperimen ke JSON dan CSV. Event yang
dicatat mencakup pembuatan SOS, request advertising, packet diterima, duplicate,
relay queued/dropped, ACK, gateway upload, service lifecycle, dan recovery.

Metrik utama:

- delivery success rate;
- end-to-end latency;
- relay latency;
- gateway latency;
- ACK latency;
- duplicate rate;
- forwarding overhead;
- RSSI terhadap keberhasilan penerimaan.

Panduan lengkap ada di
[`docs/experiment_protocol.md`](docs/experiment_protocol.md).

## Permission Android

Permission utama:

- `INTERNET` untuk gateway.
- `ACCESS_FINE_LOCATION` untuk lokasi SOS dan BLE scan pada banyak versi Android.
- `BLUETOOTH_SCAN` dan `BLUETOOTH_ADVERTISE` untuk Android 12+.
- `FOREGROUND_SERVICE` dan tipe foreground service terkait.
- `POST_NOTIFICATIONS` untuk Android 13+.
- `RECEIVE_BOOT_COMPLETED` untuk recovery setelah reboot.

## Pengujian Developer

```bash
dart format .
flutter analyze
flutter test
flutter build apk --debug
```

Unit test mencakup protocol pack/unpack, hop saturasi, persistent SOS,
adaptive backoff, forwarding policy, relay queue, ACK anti-message, gateway
contract, dan experiment logger.

## Kompatibilitas dan Limitasi

- Daftar kompatibilitas perangkat:
  [`docs/device_compatibility.md`](docs/device_compatibility.md)
- Known limitations:
  [`docs/known_limitations.md`](docs/known_limitations.md)

Hasil perangkat fisik harus dicatat per model karena kebijakan background BLE
dan battery optimization berbeda antar vendor Android.
