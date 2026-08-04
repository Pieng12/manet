# Experiment Protocol

Dokumen ini menjelaskan cara menjalankan sesi eksperimen ResQMesh setelah event
log dan export data tersedia.

## Konfigurasi Build

Mode offline BLE:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=offline \
  --dart-define=RESQMESH_FORWARDING_MODE=controlled
```

Mode gateway:

```bash
flutter run \
  --dart-define=RESQMESH_MODE=gateway \
  --dart-define=RESQMESH_API_BASE_URL=https://example.com/api \
  --dart-define=RESQMESH_FORWARDING_MODE=controlled
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
- `BLE_PACKET_RECEIVED`
- `BLE_PACKET_STORED`
- `BLE_PACKET_DUPLICATE`
- `BLE_RELAY_QUEUED`
- `BLE_RELAY_DROPPED`
- `ACK_RECEIVED`
- `ACK_ACCEPTED`
- `GATEWAY_DETECTED`
- `GATEWAY_UPLOAD_STARTED`
- `GATEWAY_UPLOAD_SUCCEEDED`
- `GATEWAY_UPLOAD_FAILED`
- `SERVICE_STARTED`
- `SERVICE_STOPPED`
- `RELAY_STATE_RECOVERED`

## Export

Buka Relay Monitor, lalu tekan `Export Experiment Data`. Aplikasi membuat file:

- `resqmesh_<session_id>.json`
- `resqmesh_<session_id>.csv`

## Metrik

Hitung metrik dari event export:

- Delivery success rate: pesan unik yang diterima tujuan dibagi pesan unik yang
  dibuat sumber.
- End-to-end latency: `BLE_PACKET_RECEIVED.timestamp_ms` pada tujuan dikurangi
  `SOS_CREATED.timestamp_ms` pada sumber.
- Relay latency: `BLE_RELAY_QUEUED.timestamp_ms` dikurangi
  `BLE_PACKET_STORED.timestamp_ms`.
- Gateway latency: `GATEWAY_UPLOAD_SUCCEEDED.timestamp_ms` dikurangi
  `GATEWAY_UPLOAD_STARTED.timestamp_ms`.
- Duplicate rate: jumlah `BLE_PACKET_DUPLICATE` dibagi jumlah
  `BLE_PACKET_RECEIVED`.
- Forwarding overhead: jumlah `BLE_ADVERTISE_REQUESTED` dibagi pesan unik yang
  delivered.

Timestamp lintas perangkat bergantung pada sinkronisasi clock. Untuk durasi
dalam satu perangkat, gunakan event dari session yang sama.

Catatan forwarding terbaru: `max_hop`, `message_lifetime_ms`, dan
`relay_cooldown_ms` pada session adalah metadata eksperimen/legacy. SOS aktif
diteruskan secara persistent sampai ACK server, state lebih baru, atau deletion.
Hitung dampak adaptive backoff dari `relay_count`, `last_relayed_at`, dan event
advertising.
