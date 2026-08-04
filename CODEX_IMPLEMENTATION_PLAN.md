# CODEX IMPLEMENTATION PLAN — ResQMesh

> Letakkan file ini di root repository sebagai `CODEX_IMPLEMENTATION_PLAN.md`.
>
> Dokumen ini adalah daftar kerja utama untuk memperbaiki project ResQMesh agar menjadi aplikasi relay pesan SOS berbasis Bluetooth Low Energy yang layak diuji sebagai sistem **Delay-Tolerant Networking (DTN)** dengan **controlled flooding**, **store-carry-and-forward**, dan **opportunistic gateway** pada Android.

---

## 1. Tujuan Akhir Sistem

Bangun aplikasi Android yang dapat:

1. Membuat pesan SOS beserta lokasi.
2. Menyimpan pesan ke SQLite sebelum pengiriman.
3. Mengemas pesan menjadi payload BLE 17 byte.
4. Menyiarkan payload melalui BLE Advertising tanpa pairing dan tanpa koneksi GATT.
5. Menerima payload melalui BLE Scanning.
6. Menyimpan dan meneruskan payload menggunakan controlled flooding.
7. Membatasi penyebaran dengan hop limit, lifetime, cooldown, dan deduplikasi.
8. Membawa pesan selama koneksi terputus dan meneruskannya ketika bertemu node lain.
9. Mengirim pesan ke server saat perangkat mempunyai internet yang benar-benar dapat digunakan.
10. Menerima ACK dari server dan menyebarkannya kembali melalui BLE.
11. Menghentikan relay pesan yang sudah diakui server.
12. Menangani beberapa pesan secara adil menggunakan relay queue.
13. Mencatat metrik eksperimen: waktu, hop, RSSI, duplicate, relay count, gateway latency, ACK latency, dan konsumsi baterai.
14. Tetap bekerja pada foreground, background, app removed, Doze, dan setelah boot sejauh diizinkan Android.
15. Menyediakan test dan dokumentasi yang dapat direproduksi.

---

# 2. Aturan Pengerjaan untuk Codex

1. Jangan menghapus fitur yang sudah berjalan tanpa alasan teknis.
2. Kerjakan perubahan secara bertahap sesuai urutan prioritas di dokumen ini.
3. Setelah setiap tahap:
   - jalankan `dart format .`;
   - jalankan `flutter analyze`;
   - jalankan `flutter test`;
   - catat error yang belum dapat diselesaikan.
4. Jangan menganggap advertising berhasil hanya karena pemanggilan API tidak melempar exception. Gunakan callback native untuk status sebenarnya.
5. Jangan menganggap internet tersedia hanya karena Wi-Fi atau mobile data terhubung.
6. Semua konstanta eksperimen harus berada pada satu konfigurasi terpusat.
7. Jangan menyimpan state penting hanya di memory. State relay harus bertahan setelah app restart.
8. Hindari perubahan besar pada UI sebelum mesin relay dan data model stabil.
9. Jangan menambahkan Bundle Protocol penuh. Sistem menggunakan pendekatan DTN, bukan implementasi BPv7.
10. Pertahankan payload BLE maksimum 17 byte, kecuali terdapat keputusan terdokumentasi untuk mengubah protokol.

---

# 3. Masalah Kritis yang Harus Diperbaiki

## P0-1 — `hopCount` selalu kembali ke nol

### Masalah

`BlePacket.unpack()` sudah membaca `hopCount`, tetapi ketika paket SOS diterima:

- nilai hop tidak disimpan pada `SOSMessage`;
- `BleRelayService` membuat ulang `SOSMessage` tanpa hop;
- `BleAdvertiserService.startAdvertising()` memanggil `BlePacket.packSos(message)` dengan default `hopCount = 0`.

Akibatnya, setiap relay terlihat sebagai hop 0.

### File yang diubah

- `lib/models/sos_message.dart`
- `lib/database_schema.dart`
- `lib/services/database_helper.dart`
- `lib/services/ble_protocol.dart`
- `lib/services/ble_relay_service.dart`
- `lib/services/ble_advertiser_service.dart`
- `test/ble_protocol_test.dart`

### Perubahan

Tambahkan ke `SOSMessage`:

```dart
int hopCount;
int maxHop;
```

Default:

```dart
hopCount = 0
maxHop = 5
```

Ketika menerima payload:

```text
incomingHop = packet.hopCount
relayHop = incomingHop + 1
```

Aturan:

```text
jika incomingHop >= maxHop:
    simpan pesan
    jangan relay
```

Saat membuat payload relay:

```dart
BlePacket.packSos(
  message,
  hopCount: message.hopCount,
)
```

Pastikan origin node mengirim hop 0, relay pertama mengirim hop 1, dan seterusnya.

### Kriteria selesai

- Test hop 0 → 1 lulus.
- Test hop 4 → 5 lulus.
- Test hop mencapai batas → tidak direlay.
- Hop tetap benar setelah app restart.

---

## P0-2 — Belum ada message lifetime atau expiry

### Masalah

Pesan dapat tetap tersimpan dan disiarkan sampai menerima ACK tanpa batas waktu.

### File yang diubah

- `lib/models/sos_message.dart`
- `lib/database_schema.dart`
- `lib/services/database_helper.dart`
- `lib/services/ble_relay_service.dart`
- `lib/services/ble_advertiser_service.dart`
- file konfigurasi baru: `lib/config/mesh_config.dart`

### Perubahan

Tambahkan:

```dart
int expiresAt;
```

Konfigurasi default:

```dart
defaultMessageLifetime = Duration(hours: 6)
```

Aturan:

```text
expired jika now >= expiresAt
```

Pesan expired:

- tidak diiklankan;
- tidak direlay;
- tidak dikirim ke server sebagai pesan aktif;
- tetap dapat disimpan untuk log penelitian;
- diberi state lokal `expired`.

Jangan menambah status `expired` ke byte status BLE jika tidak diperlukan. Gunakan kolom lokal atau derived property.

### Kriteria selesai

- Pesan aktif sebelum expiry dapat direlay.
- Pesan expired tidak direlay.
- Cleanup tidak menghapus data eksperimen sebelum diekspor.

---

## P0-3 — Tidak ada relay queue untuk beberapa pesan

### Masalah

Advertiser hanya memilih satu pesan unsynced terbaru. Pesan lain dapat mengalami starvation.

### File baru

- `lib/services/relay_queue_service.dart`
- `lib/models/relay_queue_item.dart`

### File yang diubah

- `lib/services/ble_advertiser_service.dart`
- `lib/services/ble_relay_service.dart`
- `lib/services/database_helper.dart`
- `lib/main.dart`

### Perubahan

Implementasikan persistent relay queue.

Setiap item minimal menyimpan:

```dart
String messageId;
int priority;
int nextEligibleAt;
int relayCount;
int lastRelayedAt;
bool isAck;
```

Strategi awal:

1. ACK valid.
2. SOS aktif yang belum pernah direlay.
3. SOS aktif dengan relay count paling sedikit.
4. Pesan yang paling lama tidak mendapat slot.
5. Pesan terbaru hanya sebagai tie-breaker.

Gunakan round-robin berbobot. Jangan terus mengiklankan satu pesan tanpa memberi slot ke pesan lain.

Durasi slot configurable, misalnya:

```dart
relaySlotDuration = Duration(seconds: 5)
```

### Kriteria selesai

- Tiga pesan aktif seluruhnya memperoleh slot advertising.
- Tidak ada pesan yang starvation.
- Queue bertahan setelah app restart.
- ACK dapat memotong antrean dengan prioritas tinggi.

---

## P0-4 — Opportunistic gateway nonaktif secara default

### Masalah

`RESQMESH_OFFLINE_ONLY` default-nya `true`, sehingga gateway tidak aktif pada build biasa.

### File yang diubah

- `lib/sync_service.dart`
- `lib/services/api_service.dart`
- `lib/config/mesh_config.dart`
- `README.md`

### Perubahan

Ganti konfigurasi menjadi eksplisit:

```text
RESQMESH_MODE=offline
RESQMESH_MODE=gateway
```

Atau:

```dart
enum ResqMeshMode { offline, gateway }
```

Untuk build eksperimen gateway:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=gateway \
  --dart-define=RESQMESH_API_BASE_URL=https://...
```

Jangan aktifkan endpoint produksi secara diam-diam.

### Kriteria selesai

- Mode offline tidak mencoba server.
- Mode gateway mencoba server.
- Mode aktif terlihat pada UI/log.
- README menjelaskan cara menjalankan kedua mode.

---

## P0-5 — Pemeriksaan gateway hanya berdasarkan jenis koneksi

### Masalah

`connectivity_plus` hanya menunjukkan interface jaringan, bukan akses internet atau keterjangkauan server.

### File yang diubah

- `lib/sync_service.dart`
- `lib/services/api_service.dart`

### Perubahan

Syarat gateway:

```text
network interface tersedia
AND
server health check berhasil
```

Perbaiki `ApiService.ping()` agar memakai endpoint tetap, misalnya:

```text
GET /health
```

Jangan membentuk URL menggunakan `$_baseUrl/../`.

Tambahkan timeout dan retry terbatas:

```text
timeout = 5 detik
max retry = 2
```

Simpan waktu:

```dart
gatewayDetectedAt;
gatewayUploadStartedAt;
gatewayUploadCompletedAt;
```

### Kriteria selesai

- Wi-Fi tanpa internet tidak dianggap gateway.
- Server tidak dapat dijangkau tidak dianggap gateway aktif.
- Gateway latency dapat dihitung.

---

# 4. Controlled Flooding

## P1-1 — Tambahkan kebijakan controlled flooding

### File baru

- `lib/services/forwarding_policy.dart`
- `lib/models/forwarding_decision.dart`

### File yang diubah

- `lib/services/ble_relay_service.dart`
- `lib/services/relay_queue_service.dart`
- `lib/config/mesh_config.dart`

### Aturan minimal

Pesan hanya direlay jika:

1. header dan payload valid;
2. pesan belum expired;
3. `hopCount < maxHop`;
4. ACK valid belum diterima;
5. pesan lebih baru daripada state lokal;
6. belum melewati `maxRelayCount`;
7. cooldown per pesan sudah selesai;
8. relay queue memiliki slot;
9. payload bukan berasal dari perangkat sendiri;
10. tidak terkena deduplication suppression.

Konfigurasi:

```dart
maxHop = 5;
maxRelayCount = 10;
relayCooldown = Duration(seconds: 10);
relayJitterMin = Duration(milliseconds: 300);
relayJitterMax = Duration(milliseconds: 1500);
```

Tambahkan random jitter sebelum relay untuk mengurangi tabrakan antar-node.

### Kriteria selesai

Setiap keputusan relay menghasilkan alasan log:

```text
RELAY_ACCEPTED
DROP_EXPIRED
DROP_MAX_HOP
DROP_DUPLICATE
DROP_COOLDOWN
DROP_ACKED
DROP_MAX_RELAY
DROP_OWN_PACKET
```

---

## P1-2 — Pisahkan basic flooding dan controlled flooding

### Tujuan

Skripsi membutuhkan pembanding.

### File yang diubah

- `lib/config/mesh_config.dart`
- `lib/services/forwarding_policy.dart`
- UI monitor atau settings eksperimen

### Mode

```dart
enum ForwardingMode {
  basicFlooding,
  controlledFlooding,
}
```

Basic flooding:

- relay setiap pesan baru;
- tetap melakukan deduplikasi agar tidak infinite loop;
- tidak menggunakan jitter, cooldown, atau max relay count selain max hop keselamatan.

Controlled flooding:

- memakai semua kebijakan.

### Kriteria selesai

- Mode eksperimen dapat dipilih sebelum pengujian.
- Mode tersimpan dan muncul dalam log.
- Hasil basic dan controlled dapat dibandingkan.

---

# 5. Perubahan Model dan Database

## P1-3 — Perluas model `SOSMessage`

Tambahkan minimal:

```dart
int hopCount;
int maxHop;
int expiresAt;
int firstSeenAt;
int lastRelayedAt;
int relayCount;
int duplicateCount;
int? ackReceivedAt;
int? syncedAt;
String localState;
```

Nilai `localState`:

```text
pending
queued
advertising
relayed
synced
acked
expired
failed
```

Jangan kirim seluruh field lokal ke BLE.

---

## P1-4 — Migrasi database

Naikkan version database, misalnya dari `2` ke `3`.

Tambahkan kolom:

```sql
hop_count INTEGER NOT NULL DEFAULT 0,
max_hop INTEGER NOT NULL DEFAULT 5,
expires_at INTEGER NOT NULL DEFAULT 0,
first_seen_at INTEGER NOT NULL DEFAULT 0,
last_relayed_at INTEGER NOT NULL DEFAULT 0,
relay_count INTEGER NOT NULL DEFAULT 0,
duplicate_count INTEGER NOT NULL DEFAULT 0,
ack_received_at INTEGER NULL,
synced_at INTEGER NULL,
local_state TEXT NOT NULL DEFAULT 'pending'
```

Tambahkan tabel baru:

```sql
CREATE TABLE relay_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL,
  packet_type TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  next_eligible_at INTEGER NOT NULL DEFAULT 0,
  relay_count INTEGER NOT NULL DEFAULT 0,
  last_relayed_at INTEGER NOT NULL DEFAULT 0,
  payload_base64 TEXT NULL,
  UNIQUE(message_id, packet_type)
);
```

Tambahkan tabel log eksperimen:

```sql
CREATE TABLE experiment_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  message_id TEXT NULL,
  sender_crc INTEGER NULL,
  timestamp_ms INTEGER NOT NULL,
  hop_count INTEGER NULL,
  rssi INTEGER NULL,
  payload_hash TEXT NULL,
  detail_json TEXT NULL
);
```

### Kriteria selesai

- Upgrade database lama tidak menghapus pesan.
- Fresh install membuat seluruh tabel.
- Migration test tersedia.

---

# 6. Deduplikasi yang Benar

## P1-5 — Gunakan identitas paket yang konsisten

### Masalah

Deduplikasi native saat ini memakai alamat perangkat + hex payload dalam window 5 detik. Di Dart juga terdapat deduplikasi 5 detik. Ini berguna, tetapi belum cukup untuk controlled flooding dan alamat BLE dapat berubah.

### Perubahan

Gunakan key logis:

```text
SOS:
senderCrc + timestamp + status

ACK:
senderCrc + ackTimestamp + status
```

Tambahkan helper:

```dart
String packetIdentity(BlePacket packet)
```

Deduplikasi bertingkat:

1. short-term native suppression untuk beban CPU;
2. persistent logical deduplication pada database;
3. duplicate tetap dicatat untuk metrik, tetapi tidak direlay lagi.

### Kriteria selesai

- Paket sama dari alamat BLE berbeda tetap dikenali sebagai duplicate.
- Duplicate count bertambah.
- Duplicate tidak membuat row pesan baru.
- Duplicate tidak langsung masuk relay queue lagi.

---

# 7. ACK yang Aman

## P1-6 — Perbaiki hop dan lifetime ACK

### File yang diubah

- `lib/services/ble_protocol.dart`
- `lib/services/ble_relay_service.dart`
- `lib/services/ble_advertiser_service.dart`
- `lib/services/relay_queue_service.dart`
- `lib/config/mesh_config.dart`

### Perubahan

ACK harus memiliki:

```text
hopCount
maxAckHop
expiresAt lokal
relayCount
dedup key
```

Aturan:

```text
jika ACK expired → drop
jika ACK hop >= maxAckHop → proses lokal, jangan relay
jika ACK sudah pernah direlay → jangan relay lagi sebelum cooldown
```

Konfigurasi awal:

```dart
maxAckHop = 5;
ackLifetime = Duration(minutes: 2);
ackAdvertiseDuration = Duration(seconds: 10);
```

Saat menerima ACK:

- cocokkan `senderCrc`;
- validasi timestamp;
- hentikan pesan yang sesuai;
- hapus pesan tersebut dari relay queue;
- relay ACK dengan `hop + 1` jika masih diizinkan.

### Kriteria selesai

- ACK lama tidak mematikan pesan baru.
- ACK valid menghentikan pesan terkait.
- ACK tidak menyebar tanpa batas.
- ACK hop meningkat dengan benar.

---

# 8. BLE Native Android

## P1-7 — Matikan scan-all untuk mode eksperimen

### File yang diubah

- `android/app/src/main/kotlin/com/example/pkmproject/NativeBleManager.kt`

### Perubahan

Ganti:

```kotlin
DEBUG_SCAN_ALL_ADVERTISEMENTS = true
```

menjadi konfigurasi build atau argument dari Flutter.

Mode produksi/eksperimen:

- filter manufacturer ID;
- filter service UUID bila sesuai;
- jangan scan semua advertisement.

Mode debug manual boleh scan all, tetapi harus terlihat jelas pada log.

### Kriteria selesai

- Mode eksperimen hanya memproses paket ResQMesh.
- Mode debug-all tidak menjadi default.
- Penggunaan baterai tidak tercampur dengan scanning semua beacon sekitar.

---

## P1-8 — Advertising harus benar-benar connectionless

### File yang diubah

- `android/app/src/main/kotlin/com/example/pkmproject/NativeBleAdvertiser.kt`
- `lib/services/ble_advertiser_service.dart`

### Perubahan

Untuk mode penelitian:

```kotlin
.setConnectable(false)
```

Pisahkan `debugVisible` dari `connectable`.

Jangan gunakan satu boolean untuk dua tujuan berbeda.

Contoh:

```kotlin
debugIncludeTxPower: Boolean
connectable: Boolean = false
```

### Kriteria selesai

- Advertising SOS dan ACK selalu non-connectable.
- Debug metadata tidak mengubah topologi komunikasi.

---

## P1-9 — Status advertiser harus mengikuti callback

### Masalah

`startAdvertising()` mengembalikan `true` segera setelah memanggil API, walaupun callback dapat gagal.

### Perubahan

Gunakan `CompletableDeferred`, callback channel, atau state callback ke Flutter.

Status:

```text
starting
active
failed
stopped
```

Kirim error code ke Flutter.

### Kriteria selesai

- UI tidak menampilkan active sebelum callback sukses.
- Error `DATA_TOO_LARGE`, `FEATURE_UNSUPPORTED`, dan lainnya tercatat.
- Watchdog hanya restart jika advertiser benar-benar tidak aktif.

---

## P1-10 — Perbaiki atau hapus fallback advertising

### Masalah

Fallback Flutter hanya menyiarkan service UUID, bukan payload SOS 17 byte.

### Opsi yang disarankan

Untuk penelitian, hapus fallback sebagai jalur sukses.

Jika native advertiser gagal:

```text
state = unsupported/failed
jangan tandai advertising aktif
```

Fallback hanya boleh dipertahankan jika library dapat mengirim manufacturer data yang identik.

### Kriteria selesai

- Tidak ada status sukses palsu.
- Perangkat yang tidak mendukung advertising ditandai tidak kompatibel.

---

## P1-11 — Manufacturer ID

`0xFFFF` adalah ID uji/reserved dan tidak ideal untuk produksi.

Untuk penelitian internal masih dapat digunakan jika didokumentasikan, tetapi:

- definisikan sebagai konstanta konfigurasi;
- jangan mengklaim sebagai ID produksi resmi;
- seluruh node eksperimen harus konsisten;
- filter scanner harus menggunakan ID yang sama.

---

# 9. Background Service dan Android Lifecycle

## P2-1 — Uji dan perbaiki `onTaskRemoved`

### Masalah

Service berhenti ketika aplikasi dihapus dari recent apps.

### File yang diubah

- `MeshBackgroundService.kt`
- `BackgroundServiceManager`
- dokumentasi eksperimen

### Perubahan

Tentukan perilaku yang diinginkan:

- scanning PendingIntent tetap terdaftar;
- service boleh berhenti saat idle;
- payload valid membangunkan service kembali;
- jangan menjanjikan service selalu aktif.

Pastikan `onTaskRemoved()` tidak menghapus state relay atau menghentikan scan permanen.

### Kriteria selesai

Uji:

1. foreground;
2. background;
3. app swipe-away;
4. screen off;
5. Doze;
6. reboot.

Catat hasil per perangkat.

---

## P2-2 — Boot recovery

Saat boot:

- buka database;
- pulihkan relay queue;
- hapus item expired;
- lanjutkan scan;
- lanjutkan advertising pesan yang masih aktif;
- jangan mengiklankan pesan yang sudah ACK.

### Kriteria selesai

Setelah reboot, pesan valid kembali masuk rotasi tanpa dibuat ulang.

---

## P2-3 — Battery optimization

Jangan hanya mengembalikan `true` pada `requestIgnoreBatteryOptimizations`.

Implementasikan intent Android yang benar untuk membuka permintaan battery optimization exemption jika memang diperlukan.

Catat apakah izin diberikan. Jangan memaksa pengguna.

---

# 10. Gateway dan Server

## P2-4 — Idempotency upload

Server harus dapat menerima upload yang sama lebih dari sekali tanpa membuat duplikasi.

Gunakan:

```text
local_message_id
sender_device_id
sender_crc
updated_at
```

sebagai idempotency identity.

Client:

- anggap retry sebagai normal;
- jangan menandai synced sebelum respons valid;
- simpan `syncedAt`.

---

## P2-5 — ACK contract

Dokumentasikan respons server yang pasti.

Contoh:

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

Client tidak boleh mempunyai terlalu banyak format fallback yang ambigu tanpa dokumentasi.

Tambahkan integration test menggunakan mock server.

---

# 11. Metrik Penelitian

## P2-6 — Experiment session

### File baru

- `lib/services/experiment_logger.dart`
- `lib/models/experiment_session.dart`
- `lib/services/experiment_export_service.dart`

Setiap sesi memiliki:

```dart
String sessionId;
String deviceId;
String deviceModel;
String androidVersion;
String forwardingMode;
int maxHop;
int messageLifetimeMs;
int relayCooldownMs;
int startedAt;
int? endedAt;
```

### Event minimal

```text
SOS_CREATED
BLE_ADVERTISE_REQUESTED
BLE_ADVERTISE_STARTED
BLE_ADVERTISE_FAILED
BLE_PACKET_RECEIVED
BLE_PACKET_DUPLICATE
BLE_PACKET_STORED
BLE_RELAY_QUEUED
BLE_RELAY_STARTED
BLE_RELAY_DROPPED
GATEWAY_DETECTED
GATEWAY_UPLOAD_STARTED
GATEWAY_UPLOAD_SUCCEEDED
GATEWAY_UPLOAD_FAILED
ACK_RECEIVED
ACK_ACCEPTED
ACK_REJECTED
MESSAGE_EXPIRED
SERVICE_STARTED
SERVICE_STOPPED
```

Catat RSSI dari native receiver sampai database event.

### Kriteria selesai

Data dapat diekspor menjadi CSV atau JSON.

---

## P2-7 — Definisi metrik

Hitung:

```text
Delivery success rate
= jumlah pesan unik yang diterima tujuan / jumlah pesan unik yang dikirim
```

```text
End-to-end latency
= first_received_at_tujuan - created_at_origin
```

```text
Relay latency
= relay_started_at - first_received_at
```

```text
Gateway latency
= gateway_upload_succeeded_at - first_received_at_gateway
```

```text
ACK latency
= ack_accepted_at_origin - gateway_upload_succeeded_at
```

```text
Duplicate rate
= jumlah duplicate reception / seluruh reception
```

```text
Forwarding overhead
= total relay transmissions / unique delivered messages
```

Gunakan monotonic clock untuk durasi internal jika memungkinkan. Timestamp lintas perangkat harus diberi catatan mengenai sinkronisasi clock.

---

# 12. Keamanan dan Privasi Minimum

## P2-8 — Jangan gunakan CRC sebagai autentikasi

Dokumentasikan bahwa CRC32 hanya identifier ringkas, bukan pengamanan.

Tambahkan validasi dasar:

- header;
- panjang;
- status enum;
- rentang latitude;
- rentang longitude;
- timestamp masuk akal;
- hop tidak melebihi 63.

Jangan mencatat alamat perangkat dan lokasi pengguna ke log produksi tanpa kontrol.

Untuk skripsi saat ini, enkripsi/HMAC boleh menjadi batasan penelitian, tetapi tulis secara eksplisit.

---

# 13. Unit Test dan Integration Test

## P2-9 — Test protokol

Tambahkan:

- timestamp rollover;
- koordinat minimum/maksimum;
- invalid status;
- hop 0, 1, 5, 63;
- payload pendek/panjang;
- ACK hop increment;
- invalid timestamp terlalu jauh.

---

## P2-10 — Test forwarding policy

Test:

```text
new packet → relay
duplicate packet → drop
expired packet → drop
max hop packet → store but no relay
cooldown active → defer
ACKed packet → drop
own packet received → drop
newer packet → replace
older packet → drop
```

---

## P2-11 — Test relay queue

Test:

- tiga pesan mendapat slot;
- ACK mendapat prioritas;
- expired item dikeluarkan;
- queue pulih setelah restart;
- tidak ada duplicate queue item;
- round-robin adil.

---

## P2-12 — Test database migration

Test upgrade dari versi 2 ke versi baru tanpa kehilangan data.

---

## P2-13 — Test gateway

Gunakan mock server:

- health sukses;
- health timeout;
- upload sukses;
- upload retry;
- ACK valid;
- ACK lama;
- server 404;
- server 500;
- Wi-Fi tersambung tetapi server gagal.

---

# 14. UI yang Perlu Ditambahkan

## P3-1 — Monitor eksperimen

Tampilkan:

- mode forwarding;
- scan state;
- advertiser state;
- message queue size;
- current advertised message;
- hop;
- relay count;
- duplicate count;
- gateway state;
- last gateway result;
- battery level;
- background service state;
- session ID.

---

## P3-2 — Detail pesan

Tampilkan:

- sender CRC;
- created time;
- first seen;
- last relayed;
- hop/max hop;
- relay count;
- duplicate count;
- expiry;
- sync state;
- ACK state.

---

## P3-3 — Konfigurasi eksperimen

Boleh dibuat hanya pada debug build:

- basic/controlled flooding;
- max hop;
- lifetime;
- cooldown;
- slot duration;
- gateway enabled;
- start/stop experiment;
- export data.

Konfigurasi harus terkunci setelah sesi eksperimen dimulai agar hasil konsisten.

---

# 15. Dokumentasi Repository

## P3-4 — Ganti README

README minimal harus memuat:

1. Ringkasan ResQMesh.
2. Status project.
3. Arsitektur.
4. Alur SOS.
5. Alur relay.
6. Alur gateway dan ACK.
7. Format payload 17 byte.
8. Persyaratan perangkat.
9. Cara build.
10. Cara menjalankan mode offline.
11. Cara menjalankan mode gateway.
12. Cara menjalankan test.
13. Cara memulai sesi eksperimen.
14. Cara mengekspor data.
15. Keterbatasan.
16. Catatan privasi dan keamanan.

Gunakan isi `DOKUMENTASI_RESQMESH_BLE.md` sebagai dasar, lalu sinkronkan dengan implementasi terbaru.

---

# 16. Konfigurasi Terpusat

## File baru

`lib/config/mesh_config.dart`

Contoh:

```dart
enum ForwardingMode {
  basicFlooding,
  controlledFlooding,
}

enum ResqMeshMode {
  offline,
  gateway,
}

class MeshConfig {
  static const int protocolLength = 17;
  static const int defaultMaxHop = 5;
  static const int maxRelayCount = 10;

  static const Duration defaultMessageLifetime = Duration(hours: 6);
  static const Duration ackLifetime = Duration(minutes: 2);
  static const Duration relayCooldown = Duration(seconds: 10);
  static const Duration relaySlotDuration = Duration(seconds: 5);
  static const Duration relayJitterMin = Duration(milliseconds: 300);
  static const Duration relayJitterMax = Duration(milliseconds: 1500);

  static const bool scanAllAdvertisements = false;
  static const bool connectableAdvertising = false;
}
```

Semua service harus membaca konfigurasi dari sumber yang sama.

---

# 17. Urutan Implementasi

Kerjakan dalam urutan ini:

## Tahap 1 — Fondasi data

- [ ] Tambah `hopCount`, `maxHop`, `expiresAt`, dan metadata relay ke model.
- [ ] Buat migrasi database.
- [ ] Tambah test migrasi.
- [ ] Tambah konfigurasi terpusat.

## Tahap 2 — Perbaikan protokol dan relay

- [ ] Perbaiki hop increment.
- [ ] Tambah max hop.
- [ ] Tambah expiry.
- [ ] Tambah packet identity.
- [ ] Tambah forwarding policy.
- [ ] Tambah basic dan controlled flooding.
- [ ] Tambah test forwarding.

## Tahap 3 — Queue

- [ ] Buat persistent relay queue.
- [ ] Tambah round-robin.
- [ ] Tambah prioritas ACK.
- [ ] Tambah test fairness.

## Tahap 4 — ACK

- [ ] Perbaiki ACK hop.
- [ ] Tambah ACK lifetime.
- [ ] Tambah dedup ACK.
- [ ] Tambah ACK queue priority.
- [ ] Tambah test ACK.

## Tahap 5 — Native BLE

- [ ] Matikan scan-all default.
- [ ] Paksa non-connectable.
- [ ] Perbaiki callback advertiser.
- [ ] Hapus status sukses palsu fallback.
- [ ] Tambah compatibility state.

## Tahap 6 — Gateway

- [ ] Buat mode gateway eksplisit.
- [ ] Gunakan health check server.
- [ ] Tambah idempotency.
- [ ] Tetapkan kontrak ACK.
- [ ] Tambah integration test.

## Tahap 7 — Background

- [ ] Perbaiki recovery setelah app removed.
- [ ] Pulihkan queue setelah boot.
- [ ] Implementasikan battery optimization request.
- [ ] Uji Doze dan screen-off.

## Tahap 8 — Penelitian

- [ ] Buat experiment session.
- [ ] Simpan event log.
- [ ] Catat RSSI.
- [ ] Ekspor CSV/JSON.
- [ ] Tambah monitor eksperimen.
- [ ] Dokumentasikan protokol pengujian.

## Tahap 9 — Dokumentasi

- [ ] Ganti README.
- [ ] Sinkronkan dokumentasi teknis.
- [ ] Tambah daftar perangkat kompatibel.
- [ ] Tambah known limitations.

---

# 18. Definition of Done

Project dianggap siap diuji sebagai aplikasi skripsi jika seluruh kondisi berikut terpenuhi:

## Fungsi inti

- [ ] SOS dapat dibuat tanpa internet.
- [ ] SOS tersimpan sebelum advertising.
- [ ] Payload tepat 17 byte.
- [ ] Perangkat kedua menerima SOS.
- [ ] Perangkat ketiga menerima hasil relay.
- [ ] Hop berubah 0 → 1 → 2.
- [ ] Relay berhenti pada max hop.
- [ ] Pesan expired tidak direlay.
- [ ] Beberapa pesan mendapat slot secara adil.
- [ ] Duplicate tidak membuat pesan baru.
- [ ] Gateway mengirim pesan ketika server dapat dijangkau.
- [ ] ACK valid kembali ke jaringan BLE.
- [ ] ACK menghentikan pesan yang sesuai.
- [ ] ACK lama tidak menghentikan pesan baru.
- [ ] Queue dan state pulih setelah restart.

## Android

- [ ] Advertising non-connectable.
- [ ] Scanner tidak scan-all pada mode eksperimen.
- [ ] Status advertising berasal dari callback.
- [ ] Perangkat unsupported terdeteksi.
- [ ] Background diuji.
- [ ] App removed diuji.
- [ ] Screen off diuji.
- [ ] Doze diuji.
- [ ] Reboot diuji.

## Penelitian

- [ ] Basic flooding tersedia.
- [ ] Controlled flooding tersedia.
- [ ] Session ID tersedia.
- [ ] Event log tersedia.
- [ ] RSSI tersedia.
- [ ] Data dapat diekspor.
- [ ] Delivery rate dapat dihitung.
- [ ] End-to-end latency dapat dihitung.
- [ ] Duplicate rate dapat dihitung.
- [ ] Forwarding overhead dapat dihitung.
- [ ] Gateway dan ACK latency dapat dihitung.
- [ ] Konfigurasi eksperimen terdokumentasi.

## Kualitas

- [ ] `dart format .` bersih.
- [ ] `flutter analyze` tanpa error.
- [ ] `flutter test` lulus.
- [ ] README lengkap.
- [ ] Tidak ada endpoint rahasia atau credential di repository.
- [ ] Tidak ada status sukses palsu.
- [ ] Known limitations terdokumentasi.

---

# 19. Batasan yang Tidak Perlu Dikerjakan Sekarang

Untuk menjaga scope skripsi S1:

- Jangan implementasikan Bluetooth Mesh resmi.
- Jangan implementasikan AODV, DSR, atau OLSR.
- Jangan implementasikan Bundle Protocol v7 penuh.
- Jangan menambahkan chat, suara, foto, atau video.
- Jangan menambahkan iOS sebelum Android stabil.
- Jangan membuat dashboard kompleks sebelum eksperimen inti berjalan.
- Jangan menambahkan enkripsi end-to-end sebelum controlled flooding stabil.
- Jangan melakukan optimasi UI besar sebelum pengujian selesai.

---

# 20. Hasil Akademik yang Diharapkan

Setelah seluruh perbaikan inti selesai, sistem dapat diteliti dengan pertanyaan:

> Bagaimana pengaruh controlled flooding terhadap delivery success rate, end-to-end delay, duplicate rate, forwarding overhead, dan konsumsi baterai dibandingkan basic flooding pada sistem relay pesan SOS berpendekatan Delay-Tolerant Networking berbasis Bluetooth Low Energy?

Judul yang sesuai:

> **Implementasi dan Analisis Controlled Flooding pada Sistem Relay Pesan SOS Berpendekatan Delay-Tolerant Networking Menggunakan Bluetooth Low Energy dan Opportunistic Gateway pada Android**

---

# 21. Instruksi Eksekusi Pertama untuk Codex

Mulai dari pekerjaan berikut dan jangan langsung mengubah seluruh project sekaligus:

1. Buat `lib/config/mesh_config.dart`.
2. Tambahkan field relay dan expiry pada `SOSMessage`.
3. Buat migrasi database.
4. Perbaiki alur `hopCount`.
5. Tambahkan unit test hop, max hop, dan expiry.
6. Jalankan format, analyze, dan test.
7. Tampilkan ringkasan file yang diubah dan error yang masih tersisa.
