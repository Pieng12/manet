# Experiment Protocol

Dokumen ini menjelaskan cara menjalankan sesi eksperimen ResQMesh setelah event
log dan export data tersedia.

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

Hitung metrik dari event export:

- Delivery success rate: `SUCCESS / (SUCCESS + FAILED)` untuk trial valid.
- End-to-end latency: first valid SOS receive pada tujuan dikurangi first
  successful SOS advertise pada source, bukan `SOS_CREATED`.
- Relay latency: `BLE_RELAY_QUEUED.timestamp_ms` dikurangi
  `BLE_PACKET_STORED.timestamp_ms`.
- Gateway latency: `GATEWAY_UPLOAD_SUCCEEDED.timestamp_ms` dikurangi
  `GATEWAY_UPLOAD_STARTED.timestamp_ms`.
- Logical duplicate ratio: jumlah `BLE_PACKET_DUPLICATE` dibagi
  `BLE_PACKET_ACCEPTED + BLE_PACKET_DUPLICATE`.
- Forwarding overhead network-wide: jumlah successful SOS TX starts dari
  `BLE_ADVERTISE_STARTED`/`BLE_RELAY_STARTED` di log gabungan semua node dibagi
  pesan logical SOS yang delivered. `BLE_ADVERTISE_REQUESTED` dan
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
