Kerjakan perbaikan ResQMesh berdasarkan commit P4 dan buat implementasi baru sebagai P5.

Repository:
https://github.com/Pieng12/manet.git

Pertahankan desain utama:

ACK-terminated persistent epidemic forwarding

Jangan mengembalikan:

* hard TTL sebagai penghenti delivery;
* hard hop limit;
* max relay count sebagai cutoff;
* penghapusan SOS aktif hanya karena usia pesan;
* ACK dengan TTL pendek.

Hop count tetap sebagai metrik dan disaturasi pada 63. Relay count tetap sebagai metrik. SOS terus diteruskan sampai menerima ACK valid, digantikan state lebih baru, atau dihapus secara administratif.

Tujuan P5 adalah membuat ResQMesh stabil untuk pengujian perangkat fisik lintas Android 8–16, terutama foreground, background, app removed, Doze, Bluetooth restart, service restart, dan reboot.

## 1. Tambahkan scheduler wake berdasarkan `next_eligible_at`

Masalah saat ini:

Setelah advertising selesai, queue menyimpan waktu berikutnya pada `next_eligible_at`. Ketika slot timer selesai tetapi belum ada packet yang eligible, advertiser berhenti dan tidak selalu bangun kembali saat backoff selesai.

Tambahkan API di `RelayQueueService`:

```dart
Future<int?> earliestNextEligibleAt();
```

Query harus mencari waktu minimum dari queue yang masih aktif:

```sql
SELECT MIN(next_eligible_at)
FROM relay_queue
WHERE queue_state != 'disabled';
```

Tambahkan timer khusus di `BleAdvertiserService`:

```dart
Timer? _queueWakeTimer;
```

Buat fungsi:

```dart
Future<void> _scheduleNextQueueWake();
```

Perilaku:

1. Batalkan timer lama.
2. Ambil `earliestNextEligibleAt()`.
3. Jika queue kosong, jangan membuat timer.
4. Jika waktunya sudah lewat, jalankan scheduler segera.
5. Jika waktunya masih di masa depan, buat timer menuju waktu tersebut.
6. Ketika timer aktif, panggil:

```dart
advertiseLatestOrStop(preemptCurrent: true);
```

Jadwalkan ulang timer setelah:

* SOS baru disimpan;
* ACK baru diterima;
* advertising berhasil;
* advertising gagal;
* item queue dihapus;
* ACK menghentikan SOS;
* recovery SOS;
* recovery ACK;
* scheduler tidak menemukan item eligible;
* service restart.

Jika `nextEligible()` mengembalikan null tetapi queue belum kosong, jangan berhenti permanen. Jadwalkan wake berdasarkan `earliestNextEligibleAt()`.

Tambahkan state scheduler:

```dart
enum RelaySchedulerState {
  stopped,
  selecting,
  advertising,
  waitingNextSlot,
  failedRetryable,
  failedPermission,
  failedUnsupported,
}
```

Gunakan state ini untuk menghindari timer ganda dan race condition.

## 2. Hapus idle-stop jika queue masih mempunyai pekerjaan

Saat ini `MeshBackgroundService` dapat berhenti setelah idle sekitar 60 detik jika advertiser tidak aktif. Hal ini salah karena adaptive backoff dapat mencapai beberapa menit.

Service hanya boleh berhenti jika semua kondisi berikut terpenuhi:

```text
relay queue kosong
ACK queue kosong
tidak ada pending native inbox
tidak ada pending ACK SharedPreferences
relay mode dinonaktifkan user
tidak ada recovery yang sedang berjalan
```

Tambahkan method channel untuk mengecek apakah masih ada persistent relay work:

```text
hasPendingRelayWork
```

Atau simpan state ringan yang dapat dibaca native.

Tambahkan preference persisten:

```text
relay_mode_enabled
```

Default dapat aktif setelah user menyetujui permission flow.

User harus dapat mengaktifkan dan menonaktifkan mode relay melalui UI.

Ketika `relay_mode_enabled == true`, foreground service tidak boleh berhenti hanya karena advertiser sedang menunggu `next_eligible_at`.

Perbarui notification agar menjelaskan state:

```text
ResQMesh aktif
Memantau dan meneruskan sinyal darurat BLE
```

Jika sedang menunggu backoff:

```text
ResQMesh aktif
Menunggu jadwal relay berikutnya
```

## 3. Ubah foreground service BLE menjadi `connectedDevice` saja

Pisahkan fungsi BLE relay dan internet sync.

Ubah manifest:

```xml
<service
    android:name=".MeshBackgroundService"
    android:enabled="true"
    android:exported="false"
    android:foregroundServiceType="connectedDevice" />
```

Hapus `dataSync` dari `foregroundServiceType`.

Pada `startForeground()`, gunakan hanya:

```kotlin
ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
```

Jangan memulai foreground service BLE sebagai `dataSync`.

Pastikan manifest tetap memiliki:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
```

Gateway upload/download harus dilakukan melalui:

* WorkManager;
* proses foreground ketika user membuka aplikasi;
* proses singkat dari listener connectivity jika aplikasi/service sudah aktif.

Jangan melakukan operasi jaringan panjang di BLE foreground service.

## 4. Pindahkan internet sync sepenuhnya ke WorkManager

Pisahkan lifecycle BLE dari lifecycle internet sync.

`MeshBackgroundService` bertanggung jawab hanya untuk:

* BLE scan;
* BLE advertising;
* scheduler relay;
* queue recovery;
* native inbox;
* ACK/SOS relay.

`WorkManagerService` bertanggung jawab untuk:

* gateway health check;
* upload SOS terbaru;
* download state server;
* menerima ACK gateway;
* memasukkan ACK melalui `acceptAndQueueAck`;
* retry dengan network constraint.

Gunakan unique work:

```dart
static const String gatewaySyncWorkName = 'resqmeshGatewaySync';
```

Gunakan:

```dart
ExistingWorkPolicy.keep
```

atau `replace` hanya jika benar-benar ingin memperbarui input.

Constraints:

```dart
Constraints(
  networkType: NetworkType.connected,
)
```

Tambahkan exponential backoff WorkManager.

Jangan membuat periodic timer Dart sebagai satu-satunya mekanisme sync ketika aplikasi background.

Setelah WorkManager menerima ACK:

1. simpan tombstone dan queue ACK melalui transaksi yang sudah ada;
2. simpan flag bahwa scheduler BLE perlu dibangunkan;
3. bila BLE foreground service sedang aktif, kirim scheduler tick;
4. bila service tidak aktif, queue tetap persisten dan dipulihkan saat service aktif kembali.

Pastikan mode offline sama sekali tidak mendaftarkan internet work.

## 5. Hindari start foreground service langsung dari receiver pada Android 12+

Saat `BleWakeUpReceiver` menerima BLE scan result, jangan selalu memanggil:

```kotlin
context.startForegroundService(...)
```

karena Android 12+ dapat menolak foreground service start dari background.

Implementasikan alur berdasarkan versi Android.

### Jika service sudah aktif

Kirim intent payload langsung ke `MeshBackgroundService`.

### Jika service belum aktif dan Android < 12

Boleh mencoba start service/foreground service sesuai versi.

### Jika service belum aktif dan Android 12+

Lakukan:

1. Gunakan `goAsync()`.
2. Simpan payload ke native persistent inbox.
3. Jadwalkan expedited WorkManager atau JobScheduler untuk memproses inbox.
4. Jangan mengandalkan start foreground service langsung dari receiver.
5. Catat error dan hasil fallback.

Tambahkan handling:

```kotlin
ForegroundServiceStartNotAllowedException
SecurityException
IllegalStateException
```

Jangan membiarkan receiver crash.

Jika relay mode sudah diaktifkan user, target utamanya adalah foreground service dimulai saat Activity masih terlihat dan tetap aktif. Receiver hanya mengirim payload ke service yang sudah berjalan.

## 6. Tambahkan permission Android lintas versi

Pertahankan permission Android 12+:

```xml
BLUETOOTH_SCAN
BLUETOOTH_ADVERTISE
BLUETOOTH_CONNECT
```

Pertahankan permission lokasi untuk koordinat SOS.

Tambahkan untuk Android 10–11:

```xml
<uses-permission
    android:name="android.permission.ACCESS_BACKGROUND_LOCATION"
    android:maxSdkVersion="30" />
```

Alur permission harus dibedakan.

### Android 6–9

Minta:

* fine location;
* coarse location jika diperlukan;
* pastikan Location Services aktif.

### Android 10–11

Tahap pertama:

* foreground location.

Tahap kedua, dengan dialog penjelasan terpisah:

* background location.

Jangan meminta background location bersamaan dengan foreground location.

### Android 12+

Minta:

* Bluetooth Scan;
* Bluetooth Advertise;
* Bluetooth Connect;
* lokasi untuk koordinat SOS.

### Android 13+

Tambahkan:

* notification permission.

### Android 14+

Sebelum memulai `connectedDevice` foreground service, pastikan:

* foreground service permission tersedia;
* Bluetooth runtime permissions sudah granted.

Tampilkan status permission terpisah pada UI:

```text
Bluetooth Scan
Bluetooth Advertise
Bluetooth Connect
Lokasi SOS
Background Location
Notifikasi
Battery Optimization
```

Jangan hanya menampilkan satu status “izin lengkap/tidak lengkap”.

## 7. Tetapkan minimum resmi Android 8

Karena scanner background memakai BLE `PendingIntent`, tetapkan dukungan resmi minimum:

```text
Android 8.0 / API 26
```

Ubah `minSdk` menjadi 26 jika tidak ada alasan kuat untuk mempertahankan API lebih rendah.

Contoh di Gradle:

```kotlin
defaultConfig {
    minSdk = 26
    targetSdk = 36
}
```

Perbarui:

* README;
* dokumentasi kompatibilitas;
* onboarding;
* error message pada perangkat tidak didukung.

Jangan mengklaim dukungan Android 5–7.

Jika tetap ingin mendukung Android 5–7, implementasikan fallback `ScanCallback`, tetapi jangan lakukan fallback setengah jadi. Pilihan yang direkomendasikan untuk penelitian adalah API 26+.

## 8. Tambahkan native persistent inbox untuk incoming BLE packet

Masalah:

Packet dapat hilang ketika Flutter headless engine belum siap, service sedang restart, atau receiver mempunyai waktu eksekusi terbatas.

Tambahkan native persistent inbox.

Boleh menggunakan:

* Room;
* SQLiteOpenHelper;
* file JSON queue yang aman dan atomik.

Struktur minimal:

```text
native_ble_inbox
id
payload_base64
device_address
rssi
received_at
processed_at
attempt_count
state
```

State:

```text
pending
processing
processed
failed
```

Saat `BleWakeUpReceiver` menerima packet valid:

1. validasi panjang minimum;
2. cari header `52 4D`;
3. ambil payload 17 byte;
4. simpan ke native inbox;
5. baru mencoba mengirim ke service/Flutter.

Ketika Flutter background engine siap:

1. ambil semua inbox `pending`;
2. kirim satu per satu ke Dart;
3. tunggu acknowledgment dari Dart;
4. setelah transaksi SOS/ACK berhasil, tandai inbox sebagai `processed`;
5. jika gagal, increment `attempt_count`;
6. lakukan retry dengan batas wajar dan backoff.

Tambahkan method channel:

```text
getPendingBleInbox
acknowledgeBleInboxItem
failBleInboxItem
```

Atau buat native service yang mengirim otomatis dan menerima callback.

Dedup native inbox berdasarkan:

```text
payload hash
sender CRC
timestamp
status
```

Jangan dedup hanya berdasarkan alamat BLE karena alamat dapat berubah.

Lakukan cleanup administratif untuk inbox yang sudah processed, misalnya setelah 7–30 hari. Cleanup ini bukan TTL delivery SOS.

## 9. Tambahkan capability diagnostics dan advertiser reconciliation

Buat halaman `Device Diagnostics`.

Tampilkan:

```text
Android SDK
Device manufacturer/model
Bluetooth enabled
Location service enabled
BLE scanner available
BLE advertiser available
Multiple advertising supported
Required permissions
Background location
Notification permission
Battery optimization exemption
Foreground service active
Native scan active
Native advertiser state
Current scheduler state
Current advertised packet
SOS queue size
ACK queue size
Pending native inbox
Earliest next eligible time
Last native BLE error
```

Tambahkan native method:

```text
getBleCapabilities
```

Hasil contoh:

```json
{
  "sdkInt": 35,
  "bluetoothEnabled": true,
  "bleSupported": true,
  "scannerAvailable": true,
  "advertiserAvailable": true,
  "multipleAdvertisementSupported": true,
  "scanPermission": true,
  "advertisePermission": true,
  "connectPermission": true,
  "nativeScanActive": true,
  "nativeAdvertisingActive": false,
  "nativeAdvertisingStatus": "waiting_next_slot",
  "lastErrorCode": null
}
```

### Perbaiki race advertiser callback

Tambahkan generation ID:

```kotlin
private var advertiseGeneration = 0L
```

Setiap start:

```kotlin
val generation = ++advertiseGeneration
```

Callback `onStartSuccess` dan `onStartFailure` hanya boleh mengubah state jika generation masih sama.

Ketika timeout:

1. increment generation;
2. stop advertiser;
3. set status gagal;
4. abaikan callback lama.

Tambahkan reconciliation Dart-native:

```dart
Future<void> reconcileNativeAdvertisingState();
```

Jika Dart mengira failed tetapi native masih active:

* sinkronkan state;
* jangan increment failure berulang;
* log mismatch.

Jika Dart mengira active tetapi native stopped:

* jadwalkan retry;
* jangan langsung membuat restart loop tanpa backoff.

Tambahkan native scan status dan error handling untuk:

```text
SCAN_FAILED_ALREADY_STARTED
SCAN_FAILED_APPLICATION_REGISTRATION_FAILED
SCAN_FAILED_INTERNAL_ERROR
SCAN_FAILED_FEATURE_UNSUPPORTED
```

## 10. Perketat security, filter BLE, signing, dan identity aplikasi

### Manufacturer filter

Ubah scan filter agar tidak hanya memfilter `0xFFFF`.

Tambahkan header mask:

```kotlin
ScanFilter.Builder()
    .setManufacturerData(
        NativeBleConfig.MANUFACTURER_ID,
        byteArrayOf(0x52, 0x4D),
        byteArrayOf(0xFF.toByte(), 0xFF.toByte())
    )
    .build()
```

Tetap validasi payload 17 byte di receiver.

### Receiver security

Ubah:

```xml
android:exported="true"
```

menjadi:

```xml
android:exported="false"
```

untuk `BleWakeUpReceiver`.

Hapus intent-filter publik bila tidak diperlukan.

Gunakan explicit `PendingIntent` menuju receiver internal.

Pastikan PendingIntent:

* immutable bila sistem BLE mendukung;
* mutable hanya jika benar-benar diwajibkan API scan;
* memiliki package/component eksplisit.

### Application ID

Ganti:

```text
com.example.pkmproject
```

menjadi application ID final, misalnya:

```text
id.ac.usu.resqmesh
```

Perbarui:

* namespace Gradle;
* package Kotlin;
* MethodChannel name bila diperlukan;
* intent action;
* manifest;
* ProGuard rules;
* test references.

Jangan lakukan perubahan package setengah jadi.

### Release signing

Jangan gunakan debug signing untuk release.

Tambahkan konfigurasi signing menggunakan environment atau `key.properties`.

Jangan commit:

* keystore;
* password;
* key alias password;
* secret API.

Pastikan debug build tetap mudah digunakan untuk eksperimen.

### Manufacturer ID

Jadikan configurable:

```dart
const manufacturerId = int.fromEnvironment(
  'RESQMESH_MANUFACTURER_ID',
  defaultValue: 0xFFFF,
);
```

Nilai native Kotlin dan Dart harus konsisten.

Untuk sementara, `0xFFFF` boleh tetap digunakan sebagai build eksperimen, tetapi dokumentasikan bahwa ini bukan ID produksi resmi.

## 11. Perbaiki lifecycle Bluetooth

Saat Bluetooth dimatikan:

1. stop scan;
2. stop advertiser;
3. pertahankan queue;
4. ubah status UI menjadi `Bluetooth disabled`;
5. jangan tandai queue gagal permanen.

Saat Bluetooth dinyalakan kembali:

1. cek permissions;
2. start scan;
3. recovery queue;
4. jadwalkan wake;
5. reconcile advertiser;
6. mulai packet yang eligible.

Receiver Bluetooth state sebaiknya tersedia selama service aktif, bukan hanya ketika Activity `onResume`.

Pindahkan Bluetooth state receiver ke:

* application context;
* foreground service;
* atau receiver manifest yang aman.

Jangan hanya mendaftarkan receiver di `MainActivity`, karena ketika aplikasi background, perubahan Bluetooth tetap harus diproses.

## 12. Perbaiki reboot recovery

`BootReceiver` harus:

1. cek apakah `relay_mode_enabled` aktif;
2. cek permissions;
3. jangan menggunakan foreground service type `dataSync`;
4. mulai BLE `connectedDevice` service jika diizinkan OS;
5. jika start service ditolak, jadwalkan WorkManager recovery;
6. recovery native inbox;
7. recovery SOS queue;
8. recovery ACK queue;
9. start scan;
10. jadwalkan earliest queue wake.

Tangani:

```text
ForegroundServiceStartNotAllowedException
SecurityException
IllegalStateException
```

Catat hasil:

```text
BOOT_RECOVERY_STARTED
BOOT_RECOVERY_DEFERRED
BOOT_RECOVERY_FAILED
BOOT_RECOVERY_COMPLETED
```

## 13. Perbaiki logging eksperimen

Tambahkan event:

```text
QUEUE_WAKE_SCHEDULED
QUEUE_WAKE_TRIGGERED
QUEUE_WAKE_CANCELLED
QUEUE_EMPTY
WAITING_NEXT_ELIGIBLE
NATIVE_INBOX_STORED
NATIVE_INBOX_PROCESSED
NATIVE_INBOX_FAILED
FGS_START_REJECTED
FGS_STARTED
FGS_STOPPED
FGS_KEPT_ALIVE_PENDING_QUEUE
BLE_CAPABILITY_CHECK
BLE_STATE_RECONCILED
BLE_ADVERTISER_CALLBACK_STALE
BLE_SCAN_FAILED
BLE_SCAN_RESTARTED
BLUETOOTH_DISABLED
BLUETOOTH_REENABLED
BOOT_RECOVERY_STARTED
BOOT_RECOVERY_COMPLETED
```

Detail minimal:

```text
device_id
sender_crc
message_id
packet_type
timestamp
queue_size
next_eligible_at
scheduler_state
native_state
android_sdk
device_model
error_code
forwarding_mode
```

Jangan menggunakan `deviceId: 'unknown'` jika `SyncService().deviceId` tersedia.

## 14. Tambahkan integration dan regression test

Tambahkan test berikut.

### Scheduler

1. Queue dengan item belum eligible menjadwalkan wake timer.
2. Scheduler bangun ketika `next_eligible_at` tiba.
3. Timer lama dibatalkan saat ACK baru masuk.
4. Queue kosong tidak membuat timer.
5. Service tidak berhenti jika queue masih berisi item menunggu backoff.
6. Controlled mode tetap berjalan setelah backoff lima menit.
7. Basic mode tetap berjalan pada slot dua detik.
8. Tidak ada duplicate timer.
9. Tidak ada scheduler re-entry bersamaan.

### Foreground service

10. Service type hanya `connectedDevice`.
11. Internet sync tidak dijalankan oleh BLE service.
12. Service tidak berhenti ketika advertiser inactive tetapi queue masih aktif.
13. Service berhenti jika relay mode off dan seluruh queue kosong.
14. Bluetooth off tidak menghapus queue.
15. Bluetooth on memulai recovery.

### Native inbox

16. Receiver menyimpan packet sebelum Flutter siap.
17. Packet tetap ada setelah process restart.
18. Flutter memproses pending inbox setelah startup.
19. ACK Dart mengubah inbox menjadi processed.
20. Failed processing tetap pending untuk retry.
21. Duplicate payload tidak membuat banyak record identik.
22. Invalid payload tidak masuk inbox.

### Android version routing

23. Android 8–11 menggunakan jalur service yang sesuai.
24. Android 12+ tidak memulai FGS secara buta dari receiver.
25. Android 12+ fallback menyimpan inbox dan menjadwalkan worker.
26. Android 10–11 permission flow memisahkan background location.
27. Android 13+ memeriksa notification permission.
28. Android 14+ memeriksa connected-device FGS prerequisites.

### Native advertiser

29. Callback lama tidak mengubah state advertiser baru.
30. Timeout menginvalidasi generation.
31. Dart-native reconciliation memperbaiki state mismatch.
32. FEATURE_UNSUPPORTED ditampilkan sebagai receiver-only.
33. MISSING_PERMISSION tidak membuat retry loop.
34. Bluetooth disabled menghasilkan retry setelah Bluetooth aktif.

### Security

35. Receiver internal tidak exported.
36. Scan filter memeriksa manufacturer ID dan header `RM`.
37. Intent palsu dari aplikasi lain tidak dapat memicu receiver.
38. Application ID final konsisten pada Gradle, Kotlin, manifest, dan channel.

## 15. Uji build lintas mode

Jalankan:

```bash
flutter clean
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

Build controlled offline:

```bash
flutter build apk --debug \
  --dart-define=RESQMESH_MODE=offline \
  --dart-define=RESQMESH_FORWARDING_MODE=controlled \
  --dart-define=RESQMESH_BLE_DEBUG_VISIBLE=true
```

Build basic offline:

```bash
flutter build apk --debug \
  --dart-define=RESQMESH_MODE=offline \
  --dart-define=RESQMESH_FORWARDING_MODE=basic \
  --dart-define=RESQMESH_BLE_DEBUG_VISIBLE=true
```

Build gateway:

```bash
flutter build apk --debug \
  --dart-define=RESQMESH_MODE=gateway \
  --dart-define=RESQMESH_FORWARDING_MODE=controlled \
  --dart-define=RESQMESH_API_BASE_URL=https://example.com/api
```

Build release:

```bash
flutter build apk --release \
  --dart-define=RESQMESH_MODE=offline \
  --dart-define=RESQMESH_FORWARDING_MODE=controlled
```

Jangan menyatakan build berhasil tanpa menampilkan output command.

## 16. Dokumentasi

Perbarui:

```text
README.md
DOKUMENTASI_RESQMESH_BLE.md
docs/experiment_protocol.md
docs/device_compatibility.md
docs/background_recovery_test_plan.md
docs/known_limitations.md
```

Dokumentasikan:

* minimum Android 8/API 26;
* Android 10–11 membutuhkan background location untuk background BLE scan;
* Android 12+ membatasi start FGS dari background;
* BLE FGS memakai `connectedDevice`;
* internet sync memakai WorkManager;
* queue wake berdasarkan `next_eligible_at`;
* native inbox mencegah packet hilang saat Flutter belum siap;
* dukungan background berbeda antarvendor;
* perangkat tanpa BLE advertising berstatus receiver-only;
* `0xFFFF` adalah manufacturer ID eksperimen;
* release production harus menggunakan signing dan identity final.

## 17. Output akhir Codex

Setelah selesai, tampilkan:

1. Ringkasan arsitektur P5.
2. Daftar file yang diubah.
3. Diagram lifecycle BLE foreground service.
4. Diagram scheduler wake.
5. Diagram native inbox.
6. Penjelasan routing Android 8–11 dan Android 12+.
7. Penjelasan permission per versi.
8. Cara WorkManager gateway berjalan.
9. Cara recovery Bluetooth off/on.
10. Cara reboot recovery.
11. Daftar test baru.
12. Output lengkap `flutter analyze`.
13. Output ringkas `flutter test`.
14. Output build APK debug.
15. Output build APK release.
16. Daftar keterbatasan yang masih memerlukan perangkat fisik.
17. Checklist pengujian perangkat Android 8, 10, 12, 13, 14, 15, dan 16.

Jangan menghapus test lama untuk membuat test baru lulus. Jangan mengganti algoritma mesh dengan hard TTL, hard hop, atau max relay count. Perbaiki implementasi sampai semua test dan build benar-benar berhasil.
