# Experiment Protocol

Dokumen ini menjelaskan cara menjalankan sesi eksperimen ResQMesh setelah event
log dan export data tersedia.

Rancangan terbaru memakai tiga metode, 9 kondisi dan 135 trial valid.
Panduan operasional yang berlaku: [eksperimen tiga metode](three_method_experiment.md).
Data dua metode/90 trial lama tetap arsip. `trickle_no_suppression` memakai
mesin Trickle dan seluruh aturan protokol yang sama, tetapi mengabaikan c<k
sebagai syarat suppression; tidak mengaktifkan hard TTL/hop/relay count.

## Konfigurasi Build

Mode offline BLE:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=offline \
  --dart-define=RESQMESH_FORWARDING_MODE=trickle
```

Mode gateway:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=gateway \
  --dart-define=RESQMESH_API_BASE_URL=https://example.com/api \
  --dart-define=RESQMESH_FORWARDING_MODE=trickle
```

Pembanding basic flooding:

```bash
flutter run --dart-define=RESQMESH_FORWARDING_MODE=basic
```

## Sesi Eksperimen

Saat aplikasi/service dimulai, ResQMesh membuat session aktif di tabel
`experiment_sessions`. Session menyimpan:

- `session_id`
- `device_id`
- `forwarding_mode`
- `max_hop`
- `message_lifetime_ms`
- `relay_cooldown_ms`
- `started_at`
- `ended_at`

## Event Log

Event disimpan di tabel `experiment_events` dan dapat diekspor lewat Relay
Monitor. Kolom penting:

- `event_type`
- `message_id`
- `sender_crc`
- `timestamp_ms`
- `hop_count`
- `rssi`
- `payload_hash`
- `detail_json`

Event minimal yang sudah dicatat:

- `SOS_CREATED`
- `BLE_ADVERTISE_REQUESTED`
- `BLE_ADVERTISE_STARTED`
- `BLE_ADVERTISE_FAILED`
- `BLE_PACKET_RECEIVED`
- `BLE_PACKET_STORED`
- `BLE_PACKET_DUPLICATE`
- `BLE_PACKET_STALE`
- `BLE_RELAY_QUEUED`
- `BLE_RELAY_DROPPED`
- `ACK_RECEIVED`
- `ACK_ACCEPTED`
- `ACK_TRANSACTION_COMMITTED`
- `ACK_TRANSACTION_ROLLED_BACK`
- `ACK_DUPLICATE`
- `ACK_REPLACED_NEWER_TIMESTAMP`
- `ACK_REPLACED_HIGHER_STATUS`
- `ACK_REJECTED_OLDER`
- `ACK_REJECTED_FUTURE`
- `SOS_TRANSACTION_COMMITTED`
- `SOS_TRANSACTION_ROLLED_BACK`
- `SOS_QUEUE_RECOVERED`
- `ACK_QUEUE_RECOVERED`
- `SCHEDULER_PACKET_SELECTED`
- `SCHEDULER_BLOCKED`
- `SCHEDULER_ENVIRONMENT_RESUMED`
- `HEADLESS_RELAY_ATTEMPTED`
- `HEADLESS_RELAY_STARTED`
- `HEADLESS_RELAY_FAILED`
- `NATIVE_INBOX_WORKER_STARTED`
- `NATIVE_INBOX_WORKER_COMPLETED`
- `GATEWAY_DETECTED`
- `GATEWAY_UPLOAD_STARTED`
- `GATEWAY_UPLOAD_SUCCEEDED`
- `GATEWAY_UPLOAD_FAILED`
- `SERVICE_STARTED`
- `SERVICE_STOPPED`
- `RELAY_STATE_RECOVERED`
- `TRICKLE_RESET`
- `TRICKLE_INTERVAL_STARTED`
- `TRICKLE_CONSISTENT_HEARD`
- `TRICKLE_INCONSISTENT_HEARD`
- `TRICKLE_TX_ALLOWED`
- `TRICKLE_TX_SUPPRESSED`
- `TRICKLE_STATE_RECOVERED`

## Export

Buka Relay Monitor, lalu tekan `Export Experiment Data`. Aplikasi membuat file:

- `resqmesh_<session_id>.json`
- `resqmesh_<session_id>.csv`

## Metrik

### Batas waktu pengukuran (measurement timing v2)

Controller mengaktifkan trial pada semua node sebelum membuat SOS. Aktivasi
ini bukan awal jendela metrik. Awal jendela adalah timestamp fisik callback
`SOURCE_FIRST_ADVERTISE_STARTED`, setelah koreksi clock sumber. Akhirnya tepat
60 detik setelah callback tersebut (atau durasi konfigurasi). Waktu tunggu
Trickle sebelum TX pertama tidak mengurangi durasi pengamatan. Latency tetap
first valid receive dikurangi first successful advertise; rumus empat metrik
tidak berubah. Semua event sebelum/sesudah jendela tetap diarsipkan tetapi
tidak dihitung sebagai overhead/duplicate dalam jendela.

Controller menunggu callback sumber maksimal 60 detik. Callback tidak muncul,
identitas sesi/trial/pesan berbeda, atau jendela sudah terlewat menghasilkan
`INVALID`; reset/quiet-period tetap dijalankan. Polling status tidak menggeser
timestamp awal. Penghentian node lewat command bisa terlambat karena transport;
filter event memakai batas timestamp eksplisit, bukan waktu command selesai.

Firmware menerima RX ke queue dari task NimBLE; hanya loop yang memproses
packet, persistence, counter dan scheduler. Waktu fisik RX dipertahankan.
Overflow queue dicatat sebagai pelanggaran eksperimen, bukan dibuang diam-diam.
Trickle mencatat `interval_ms`, `interval_started_at_monotonic_ms`,
`transmit_at_monotonic_ms`, `interval_end_at_monotonic_ms`, dan
`consistency_count`. Controller/merger memeriksa kesempatan `[I/2, I)` serta
burst sebelum setengah interval; delay callback native bukan TX tambahan.

Readiness APK dan firmware harus melaporkan `measurement_timing_version=2`.
Fingerprint pengukuran berubah sehingga smoke report lama tidak dapat dipakai
untuk menjalankan batch baru. Instal APK dan flash semua ESP dengan build baru,
jalankan smoke baru, lalu gunakan sesi/output baru untuk batch utama.

Dataset lama tidak ditulis ulang. Audit log `physical-20260927-11` menemukan
pelanggaran scheduler pada `trickle-H2-A001`, `trickle-H2-A006`,
`trickle-H3-A008`, dan `trickle-H3-A010` (lima burst relay). Alasannya adalah
request TX mendahului pembuatan interval, bukan semata latency rendah.
Jendela lama dimulai sebelum TX pertama dan tidak dapat diperpanjang secara
retroaktif tanpa bukti RX yang memang direkam untuk seluruh durasi baru.

Hitung metrik dari event export:

- Delivery success rate: `SUCCESS / (SUCCESS + FAILED)` untuk trial valid.
- End-to-end latency: first valid SOS receive pada tujuan dikurangi first
  successful SOS advertise pada source, bukan `SOS_CREATED`.
- Relay latency: `BLE_RELAY_QUEUED.timestamp_ms` dikurangi
  `BLE_PACKET_STORED.timestamp_ms`.
- Gateway latency: `GATEWAY_UPLOAD_SUCCEEDED.timestamp_ms` dikurangi
  `GATEWAY_UPLOAD_STARTED.timestamp_ms`.
- Logical duplicate ratio: jumlah `BLE_PACKET_DUPLICATE` dibagi
  `BLE_PACKET_ACCEPTED + BLE_PACKET_DUPLICATE`. Retry transport Android dengan
  `observation_id` yang sama hanya dicatat sebagai `BLE_TRANSPORT_DUPLICATE`
  atau `BLE_TRANSPORT_IN_PROGRESS` dan tidak masuk pembilang atau penyebut.
- Forwarding overhead network-wide: jumlah successful SOS radio TX starts dari
  event canonical `BLE_ADVERTISE_STARTED` dengan `packet_type=sos` di log
  gabungan semua node dibagi jumlah trial valid (`SUCCESS` maupun
  `FAILED_DELIVERY`).
  `BLE_RELAY_STARTED` dipakai untuk bukti relay/hop/latency dan tidak
  dijumlahkan lagi sebagai TX kedua. `BLE_ADVERTISE_REQUESTED` dan
  `TRICKLE_TX_SUPPRESSED` bukan TX sukses.

Timestamp lintas perangkat bergantung pada sinkronisasi clock. Untuk durasi
dalam satu perangkat, gunakan event dari session yang sama.

Catatan forwarding terbaru: `max_hop`, `message_lifetime_ms`, dan
`relay_cooldown_ms` pada session adalah metadata eksperimen/legacy. SOS aktif
diteruskan secara persistent sampai ACK server, state lebih baru, atau deletion.
Hitung dampak Trickle dari event interval, consistency count, suppression, dan
advertising sukses.

Timestamp BLE memakai presisi satu detik. Gunakan timestamp canonical dari
payload/identity saat menghitung duplicate, ACK tombstone, dan recovery queue.
Mode `basic` memakai interval tetap pendek plus jitter, sedangkan `trickle`
memakai interval `[Imin, Imax]`, consistency counter `k`, waktu transmit acak
`t` dalam `[I/2, I)`, dan suppression. Consistent observation menaikkan `c`
sekali per `observation_id`; raw BLE repeat dalam burst yang sama tidak
menambah `c`, tetapi burst independen berikutnya dari observer yang sama dapat
menjadi observation baru.

Untuk relay sejajar, hop satu layer di atas `expectedHopIn` hanya dianggap
consistent jika `MessageKey` dan `StateIdentity` cocok dengan state lokal.
Packet tersebut tidak mengganti state/hop lokal atau menambah queue. Pada
Trickle ia dapat menaikkan `c`; pada Basic ia hanya menambah logical duplicate.
State identity berbeda adalah informasi inkonsisten dan tidak boleh dihitung
sebagai observasi konsisten.

Readiness wajib memeriksa epoch ID, awal, akhir representasi 24-bit, sisa hari,
dan validitas. Android, firmware, dan controller memakai
`resqmesh-2026-06-01` / `1780272000`. Tidak ada nearest-window reconstruction.
Membership interval Trickle memakai `received_at` wall-clock dari native BLE
receive. Waktu drain/processing Dart hanya dipakai sebagai fallback jika
metadata receive null, nol/negatif, atau lebih dari 2 detik di masa depan.
Jangan membandingkan `received_elapsed_realtime_ms` dengan interval SQLite
karena clock domain-nya berbeda.

Transport duplicate berarti `observation_id` sama terkirim ulang lewat direct
service, WorkManager, service retry, atau native inbox drain. Jika row
`processed_ble_observations` masih `processing`, retry dicatat sebagai
`BLE_TRANSPORT_IN_PROGRESS` dan item native tetap pending. Jika sudah
`completed`, retry dicatat sebagai `BLE_TRANSPORT_DUPLICATE` dan aman di-ACK.
State `failed_retryable` atau lease `processing` yang melewati 10 menit dapat
diklaim ulang. Event transport ini tidak mewakili transmisi BLE baru dan tidak
boleh membuat `BLE_PACKET_RECEIVED`, `BLE_PACKET_DUPLICATE`, atau Trickle `c`
kedua. Logical duplicate berarti `observation_id` berbeda tetapi state SOS
logis sama; ini adalah consistent transmission yang valid untuk duplicate ratio
dan Trickle suppression.

`BLE_PACKET_RECEIVED` dihitung sebagai observasi fisik idempotent untuk
`observation_id` non-kosong dengan `event_key`
`BLE_PACKET_RECEIVED|observation_id`. Retry protocol dari `failed_retryable`
atau lease expired tetap dapat memperbaiki state durable dan mengisi event RX
yang hilang akibat crash sebelum log commit, tetapi tidak menambah event RX
normal, RSSI sample, hop-in sample, atau `ACK_RECEIVED` kedua untuk ACK yang
sama. Packet dengan `observation_id` berbeda tetap menjadi observasi fisik baru.

Untuk menjaga exactly-once boundary, satu `observation_id` hanya boleh mengubah
state protocol/research durable satu kali. Commit SOS, duplicate logical, dan
ACK menandai observation sebagai `completed` sebelum side-effect non-kritis
dijalankan. Jika advertiser, WorkManager, gateway scheduling, atau logging gagal
setelah commit, packet BLE tidak diputar ulang; persistent relay queue dan
WorkManager menangani retry masing-masing. `failed_retryable` hanya dipakai jika
transaksi protocol belum commit.

## Catatan P5 untuk Uji Perangkat Fisik

Build resmi penelitian menargetkan minimum Android 8/API 26 karena scan
background memakai BLE PendingIntent. Jalankan matrix berikut sebelum mencatat
hasil:

```bash
flutter clean
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug --dart-define=RESQMESH_MODE=offline --dart-define=RESQMESH_FORWARDING_MODE=trickle --dart-define=RESQMESH_BLE_DEBUG_VISIBLE=true
flutter build apk --debug --dart-define=RESQMESH_MODE=offline --dart-define=RESQMESH_FORWARDING_MODE=basic --dart-define=RESQMESH_BLE_DEBUG_VISIBLE=true
flutter build apk --debug --dart-define=RESQMESH_MODE=gateway --dart-define=RESQMESH_FORWARDING_MODE=trickle --dart-define=RESQMESH_API_BASE_URL=https://example.com/api
flutter build apk --release --dart-define=RESQMESH_MODE=offline --dart-define=RESQMESH_FORWARDING_MODE=trickle
```

Event P5 yang perlu diperhatikan: `QUEUE_WAKE_SCHEDULED`,
`QUEUE_WAKE_TRIGGERED`, `WAITING_NEXT_ELIGIBLE`, `NATIVE_INBOX_STORED`,
`NATIVE_INBOX_PROCESSED`, `FGS_START_REJECTED`, `FGS_STARTED`, `FGS_STOPPED`,
`BLE_STATE_RECONCILED`, `BLE_SCAN_FAILED`, `BLUETOOTH_DISABLED`,
`BLUETOOTH_REENABLED`, `BOOT_RECOVERY_STARTED`, dan
`BOOT_RECOVERY_COMPLETED`.

Untuk P7, native-only cases seperti processed exact duplicate dan permission
blocked worker perlu dibuktikan melalui logcat, diagnostics
`nativeInboxPermissionBlockedAt`, dan native inbox metadata karena Dart/SQLite
experiment logger tidak selalu berjalan pada saat permission belum tersedia.

## Physical Testbed Controller

Eksperimen utama memakai satu Android source dan lima ESP32-C3. Setiap event
yang masuk metrik wajib cocok pada `session_id`, `trial_id`, node konfigurasi,
message key, dan hop. Event tanpa trial atau event trial lama dipisahkan sebagai
diagnostic. Command response dicocokkan menggunakan `command_id` dan tidak
dicampur dengan event reader serial.

Target setiap kondisi adalah 15 trial valid. `SUCCESS` dan
`FAILED_DELIVERY` masuk penyebut DSR; `INVALID` disimpan untuk audit lalu
diganti attempt baru sampai target atau batas 45 attempt. Urutan baru
`balanced_randomized` terdiri dari 15 blok masing-masing seluruh 9 kondisi
sekali. Seed dan urutan disimpan di manifest dan dipakai kembali saat resume.

Batch harus didahului smoke ketiga metode pada H1-H3. Zero suppression sah,
bukan syarat kegagalan smoke. Smoke menghasilkan
`smoke_report.json`/`.csv`, sedangkan merger menghasilkan `events.json`,
`events.csv`, `trial_summary.csv`, `aggregate_by_mode_hop.csv`,
`invalid_trials.csv`, dan `attempt_summary.csv`.
# Migrasi Extended Coded Radio

Binary pada branch kerja Extended/Coded menggunakan interval radio tetap
250 ms, primary/secondary Coded, manufacturer `0xFFFF`, application payload
17 byte. Basic, Trickle (8000/256000 ms, k=1), burst 2 s, dan definisi metrik
tetap sama. Jangan campur dataset legacy dengan dataset radio baru.

Konfigurasi eksperimen baru harus menyatakan `"radio_mode": "coded"` secara
eksplisit. Override `nodes[].radio_mode = "coded_s8_required"` hanya untuk ESP
yang controller-nya memenuhi V2; OPPO tetap `coded`. Controller memeriksa PHY,
interval, kesiapan dan penerimaan S8 sebelum trial, serta menyimpan snapshot
radio pada manifest. Konfigurasi radio eksplisit masuk fingerprint sehingga
resume/smoke lama tidak bisa digunakan untuk konfigurasi radio berbeda.

Android public AdvertisingSet API tidak menyediakan pemilihan S8. Jangan klaim
125 kbps terkunci dari callback, RSSI, atau primary/secondary Coded. Panduan:
[Uji Windows Extended Coded](coded_radio_windows.md).
