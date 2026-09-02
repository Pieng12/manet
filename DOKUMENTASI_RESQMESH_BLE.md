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
| `RESQMESH_FORWARDING_MODE` | `trickle` | `trickle` atau `basic`. |
| `protocolLength` | `17` | Panjang payload BLE. |
| `manufacturerId` | `0xFFFF` | Manufacturer ID penelitian internal. |
| `legacyHopMetadata` | `5` | Nilai legacy/metadata, bukan cutoff relay aktif. |
| `legacyAckHopMetadata` | `5` | Nilai legacy/metadata, bukan cutoff ACK aktif. |
| `defaultMessageLifetime` | `6 jam` | Nilai legacy/metadata, bukan cutoff SOS aktif. |
| `ackLifetime` | `2 menit` | Nilai legacy/metadata, bukan TTL ACK aktif. |
| `basicFloodingInterval` | `2 detik` | Interval tetap basic flooding sebelum jitter. |
| `sosAdvertiseBurstDuration` | `2 detik` | Durasi satu burst advertising SOS untuk basic dan Trickle. |
| `trickleImin` | `8 detik` | Interval minimum Trickle untuk SOS. |
| `trickleImaxDoublings` | `5` | Jumlah doubling dari `Imin` sampai `Imax`. |
| `trickleRedundancyConstant` | `1` | Nilai `k`; suppress TX jika consistency count sudah mencapai batas. |
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
  menyertakan RSSI, menyimpan payload ke native inbox, lalu membangunkan service
  bila diizinkan OS. Timestamp receive native (`received_at`) dan monotonic
  `received_elapsed_realtime_ms` ikut diteruskan ke Dart untuk logging riset.
- `MeshBackgroundService.kt`: menjaga scan/advertising dan menghubungkan event
  native ke Dart background isolate.
- `BootReceiver.kt`: memulihkan service setelah boot.
- `NativeBatteryOptimization.kt`: membuka request battery optimization exemption.
- `NativeBleInbox.kt`: persistent inbox native untuk packet pending saat Flutter
  engine belum siap.
- `NativeBleInboxWorker.kt`: fallback WorkManager untuk recovery inbox Android
  12+ ketika foreground service start dari receiver ditolak. Worker ini
  menjalankan Dart headless untuk memproses inbox dan tidak memulai foreground
  service baru sebagai fallback.

Fallback sukses palsu untuk advertising tidak digunakan. Jika native advertising
tidak tersedia atau gagal, compatibility state harus menandai perangkat tidak
kompatibel sebagai relay aktif.

Foreground service BLE memakai tipe `connectedDevice` saja. Internet sync tidak
dikerjakan sebagai beban panjang di service BLE; gateway upload/download
dijadwalkan melalui WorkManager unique work `resqmeshGatewaySync` dengan
constraint network dan exponential backoff.

Native inbox hanya di-ack setelah Dart mengembalikan hasil eksplisit:
`accepted`, `duplicate`, `stale`, `suppressedByAck`, atau `invalid`. Hasil
`failedRetryable` tetap berada di inbox sebagai item gagal agar WorkManager bisa
mencoba lagi.
Native inbox tidak lagi memakai exact-payload suppression jangka panjang
sebagai identitas observasi. Identitas utama adalah `observation_id`: hash dari
payload 17 byte, observer key, dan bucket waktu burst. Repetisi radio mentah
dalam satu burst dari observer yang sama tetap menjadi satu observation, retry
worker atas item yang sama tetap idempotent, tetapi burst independen berikutnya
atau observer BLE berbeda membuat observation baru. `device_address` hanya
metadata diskriminator sementara dari Android scanner, bukan identitas node
permanen. Better-hop tidak hilang di native dedupe karena perubahan hop
mengubah raw payload 17 byte dan hash payload observasi. Jika alamat tidak
tersedia, fallback `unknown:<burstStartedAt>` tetap membuat observasi berbasis
burst sehingga tidak collapse permanen. Tanpa alamat BLE, dua transmitter fisik
berbeda dengan payload sama dalam bucket burst yang sama tidak selalu bisa
dibedakan reliabel.

`observer_key`, `observation_id`, `received_at`, `received_elapsed_realtime_ms`,
`device_address`, payload, dan RSSI dipropagasi dari native inbox/direct service
ke Dart. Untuk membership interval Trickle, Dart memakai `received_at` wall
clock yang tervalidasi; jika null, nol/negatif, atau lebih dari 2 detik di masa
depan, Dart fallback ke waktu processing lokal. `received_elapsed_realtime_ms`
hanya untuk diagnostik latency lokal dan tidak dibandingkan dengan interval
Trickle SQLite.

Setelah payload valid dibuka, Dart melakukan klaim persisten
`processed_ble_observations` berdasarkan `observation_id` sebelum mencatat
`BLE_PACKET_RECEIVED` atau klasifikasi forwarding. Transport duplicate adalah
retry internal Android dengan `observation_id` yang sama; ini bukan transmisi
radio baru, sehingga tidak menambah duplicate ratio, RSSI/hop sample,
`duplicate_count`, atau Trickle `c`. Logical duplicate adalah observation baru
dengan state SOS logis yang sama; ini tetap dicatat sebagai
`BLE_PACKET_DUPLICATE` dan dapat menaikkan Trickle `c`.
State klaim `processing` berarti processor lain masih mengerjakan observation
tersebut, sehingga retry native tidak di-ACK dan dicatat sebagai
`BLE_TRANSPORT_IN_PROGRESS`. State `completed` baru aman dianggap
`BLE_TRANSPORT_DUPLICATE`; state `failed_retryable` dapat diklaim ulang. Lease
`processing` 10 menit mencegah kehilangan packet saat ada race, tetapi tetap
memungkinkan recovery jika processor pertama crash.

Boundary durable protocol berada pada commit SQLite untuk SOS, duplicate
logical, dan ACK. Setelah state wajib seperti `sos_messages`, `relay_queue`,
`ack_tombstones`, dan Trickle state berhasil durable, observation harus menjadi
`completed`. Kegagalan side-effect setelah itu, termasuk log eksperimen,
trigger advertiser, WorkManager, atau gateway scheduling, tidak boleh mengubah
observation menjadi `failed_retryable`; retry TX/gateway dipulihkan dari queue
persisten. `failed_retryable` hanya berarti protocol transaction belum durable.

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

`protocol_timestamp_ms` pada log riset selalu berasal dari timestamp protokol
ini. Waktu event lokal disimpan terpisah sebagai `event_timestamp_ms`, sehingga
CSV/JSON tidak mencampur waktu penerimaan/advertising dengan state timestamp
BLE.

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

Perbedaan mode diterapkan di `RelayQueueService`, yaitu scheduler yang memilih
packet berikutnya dari persistent queue. Mode `trickle` default memakai:

- dedup berbasis identity packet;
- fairness antar SOS;
- interval Trickle `[Imin, Imax]`;
- consistency counter dan suppression;
- waktu transmit acak `t` dalam `[I/2, I)`;
- relay count sebagai metrik saja.

Basic flooding disediakan sebagai pembanding eksperimen dan memakai interval
tetap pendek plus jitter, tanpa Trickle suppression.
Mode `trickle` tidak memakai legacy relay jitter untuk SOS; randomisasi SOS
hanya berasal dari `t` Trickle dalam separuh akhir interval.
ACK tetap prioritas tinggi, tetapi scheduler membatasi slot ACK beruntun agar
SOS eligible mendapat giliran setelah batas fairness.

Istilah Trickle yang dipakai ResQMesh:

- Consistent: SOS dengan `sender_crc`, timestamp protokol, dan status yang sama,
  tanpa better-hop. Ini menaikkan `c` sekali per `observation_id` unik.
- Inconsistent: state baru atau perubahan state yang harus disebarkan. Jika
  interval saat ini lebih besar dari `Imin`, scheduler reset ke `Imin`; jika
  sudah di `Imin`, interval tidak diulang dan log mencatat
  `reset_performed=false`.
- Better-hop: integrasi ResQMesh untuk packet sender/timestamp/status yang sama
  tetapi resulting hop tersimpan lebih rendah. Ini memperbarui state dan reset
  Trickle dengan alasan `better_hop_event`.
- Stale: packet yang lebih lama atau prioritas statusnya lebih rendah sehingga
  tidak mengganti state, tidak menaikkan `c`, dan tidak mereset interval.

Jika tidak ada item eligible tetapi queue belum kosong, scheduler tidak berhenti
permanen. `RelayQueueService.earliestNextEligibleAt()` mengambil waktu minimum
`next_eligible_at` dari queue aktif, lalu `BleAdvertiserService` memasang wake
timer. State scheduler yang dilaporkan adalah `stopped`, `selecting`,
`advertising`, `waitingNextSlot`, `failedRetryable`, `failedPermission`, atau
`failedBluetoothDisabled`, atau `failedUnsupported`. Permission hilang,
Bluetooth mati, dan advertiser unsupported adalah state blocked event-driven;
scheduler tidak memasang wake timer zero-delay. Kegagalan transient memakai
exponential retry mulai 15 detik dan dibatasi 5 menit.

`trickle_observations` hanya dipakai untuk idempotency `c` pada interval aktif.
Saat interval baru aktif, observation lama untuk message tersebut dipangkas dari
tabel idempotency, sedangkan bukti penelitian tetap tersimpan di
`experiment_events`. Delayed retry dari native inbox yang timestamp receive-nya
lebih lama dari interval aktif tidak menaikkan `c` interval baru.

Advertiser native memakai generation ID agar callback lama setelah timeout atau
restart tidak merusak state advertiser baru. Dart melakukan reconciliation jika
state native dan state Dart berbeda.

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

ACK diterima jika `sender_crc` cocok, status bukan `ACTIVE`, dan timestamp ACK
tidak lebih lama dari pesan lokal. ACK valid disimpan sebagai tombstone persisten
terbaru per `sender_crc`, diprioritaskan di queue, dideduplikasi, dikompaksi,
dan disebarkan ulang tanpa hard hop limit atau TTL 2 menit sampai node pembawa
SOS menerimanya.

ACK gateway dan ACK BLE diproses melalui transaksi SQLite yang sama: validasi,
tombstone, update SOS `acked`, penghapusan SOS dari queue, compact ACK, dan
upsert ACK queue dilakukan atomik. Saat SOS diterima, tombstone dicek sebelum
pesan disimpan atau masuk relay. Jika
`ack_timestamp >= sos_timestamp`, SOS lama dianggap sudah diterminasi dan tidak
di-relay. SOS dengan timestamp yang lebih baru dari tombstone tetap diterima
sebagai state baru.

Saat startup atau recovery service, `RelayQueueService` membaca seluruh
`ack_tombstones` dan `sos_messages` aktif, lalu membangun ulang queue item yang
hilang. Untuk state lokal, timestamp dibuat monotonic per sender pada resolusi
detik agar state baru tidak memakai timestamp BLE yang sama dengan ACK atau
state sebelumnya. Packet BLE yang diterima dari node lain tidak diubah oleh
helper monotonic.

## Database Lokal

Skema saat ini mencakup:

- `sos_messages`: pesan lokal/relay, status sync, hop, metadata legacy, sender
  CRC, dan relay metadata.
- `relay_queue`: queue persisten untuk packet SOS dan ACK.
- `ack_tombstones`: ACK terbaru per sender untuk menahan relay SOS lama.
- `processed_packets`: dedup packet SOS/ACK.
- `gateway_acks`: ACK dari gateway dan metadata relay.
- `experiment_sessions`: konfigurasi dan waktu session eksperimen.
- `experiment_events`: event log, RSSI, hop, hash payload, dan detail JSON.

Timestamp protokol disimpan canonical pada presisi satu detik. Tombstone ACK,
payload ACK hasil recovery, message id BLE, dan packet identity harus memakai
nilai canonical yang sama. Migrasi database harus menambah kolom/tabel tanpa
menghapus data lama.

## Background Recovery

ResQMesh memulihkan scan, advertising, dan queue saat:

- aplikasi berjalan foreground;
- aplikasi pindah ke background;
- app removed dari recent apps;
- perangkat reboot;
- service restart;
- user mengubah battery optimization.
- Bluetooth dimatikan lalu dinyalakan lagi.
- native inbox masih memiliki packet pending.

Pada Android 8-11, receiver boleh meminta service sesuai batas OS bila permission
tersedia. Pada Android 12+, receiver menyimpan payload dulu ke native inbox dan
tidak mengandalkan start foreground service langsung saat service belum aktif;
fallback recovery dijadwalkan melalui WorkManager. Saat service dan background
Dart siap, pending inbox dibaca, diproses satu per satu, lalu native item
ditandai `processed` atau `failed`.

Checklist pengujian ada di
[`docs/background_recovery_test_plan.md`](docs/background_recovery_test_plan.md).

## Eksperimen dan Metrik

Relay Monitor menyediakan export session eksperimen ke JSON dan CSV. Event yang
dicatat mencakup pembuatan SOS, request advertising, packet diterima, duplicate,
relay queued/dropped, ACK, gateway upload, service lifecycle, dan recovery.
Untuk mode Trickle, event utama mencakup `TRICKLE_RESET`,
`TRICKLE_INTERVAL_STARTED`, `TRICKLE_CONSISTENT_HEARD`,
`TRICKLE_INCONSISTENT_HEARD`, `TRICKLE_TX_ALLOWED`,
`TRICKLE_TX_SUPPRESSED`, dan `TRICKLE_STATE_RECOVERED`.

Metrik utama:

- delivery success rate: `SUCCESS / (SUCCESS + FAILED)` untuk trial valid;
- end-to-end latency: tujuan menerima SOS valid pertama dikurangi source
  berhasil memulai advertise SOS pertama, bukan dari `SOS_CREATED`;
- relay latency;
- gateway latency;
- ACK latency;
- logical duplicate ratio: `duplicates / (accepted + duplicates)`, hanya dari
  `BLE_PACKET_DUPLICATE` SOS. `BLE_TRANSPORT_DUPLICATE` dan
  `BLE_TRANSPORT_IN_PROGRESS` adalah diagnostik retry internal dan dikeluarkan;
- forwarding overhead network-wide: total successful SOS radio TX starts dari
  event canonical `BLE_ADVERTISE_STARTED` dengan `packet_type=sos` pada log
  gabungan dibagi SOS logical yang delivered. `BLE_RELAY_STARTED` dipakai untuk
  bukti relay/hop/latency dan tidak dijumlahkan lagi sebagai TX kedua. Event
  suppressed tidak dihitung sebagai TX;
- RSSI terhadap keberhasilan penerimaan.

Panduan lengkap ada di
[`docs/experiment_protocol.md`](docs/experiment_protocol.md).

## Permission Android

Permission utama:

- `INTERNET` untuk gateway.
- `ACCESS_FINE_LOCATION` untuk lokasi SOS dan BLE scan pada banyak versi Android.
- `ACCESS_BACKGROUND_LOCATION` dengan `maxSdkVersion=30` untuk Android 10-11.
- `BLUETOOTH_SCAN` dan `BLUETOOTH_ADVERTISE` untuk Android 12+.
- `FOREGROUND_SERVICE` dan `FOREGROUND_SERVICE_CONNECTED_DEVICE`.
- `POST_NOTIFICATIONS` untuk Android 13+.
- `RECEIVE_BOOT_COMPLETED` untuk recovery setelah reboot.

Minimum resmi P5 adalah Android 8/API 26 karena background scanner memakai BLE
PendingIntent. Perangkat Android 5-7 tidak diklaim didukung tanpa fallback
`ScanCallback` khusus.

Relay Monitor menampilkan Device Diagnostics: SDK, model, Bluetooth enabled,
scanner/advertiser availability, multiple advertising support, permission
status, foreground service, scan/advertiser native state, scheduler state,
current packet, queue SOS/ACK, pending native inbox, earliest next eligible
time, dan error native terakhir.

## Research Observability P10

Research Monitor hanya membaca session aktif `RESEARCH`; event background tanpa
session penelitian aktif memakai session `AUTO`. Forwarding mode dicatat dari
build config aktual, bukan dropdown manual. Accepted packet dihitung hanya dari
`BLE_PACKET_ACCEPTED`, RSSI hanya dari `BLE_PACKET_RECEIVED`, dan hop dipisahkan
menjadi `hop_in` serta `hop_out`. Trial timeout adalah workflow eksperimen
(`FAILED/TIMEOUT`), bukan TTL protokol.

## Pengujian Developer

```bash
dart format .
flutter analyze
flutter test
flutter build apk --debug
```

Unit test mencakup protocol pack/unpack, hop saturasi, persistent SOS, Trickle
scheduler, forwarding policy, relay queue, ACK anti-message, gateway contract,
dan experiment logger.

## Kompatibilitas dan Limitasi

- Daftar kompatibilitas perangkat:
  [`docs/device_compatibility.md`](docs/device_compatibility.md)
- Known limitations:
  [`docs/known_limitations.md`](docs/known_limitations.md)

Hasil perangkat fisik harus dicatat per model karena kebijakan background BLE
dan battery optimization berbeda antar vendor Android.
