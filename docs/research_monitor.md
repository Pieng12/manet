# ResQMesh Research Monitor

Research Monitor adalah layar debug untuk eksperimen skripsi. Layar ini
mempermudah pembuatan session, penomoran trial, pemantauan BLE/relay, metrik
lokal, timeline event, dan export data mentah. Fitur ini bukan layar pengguna
darurat normal.

Research metadata disimpan di SQLite. Metadata session/trial tidak pernah
dimasukkan ke payload BLE 17 byte.

## Workflow

1. Buka `Research Monitor`.
2. Isi experiment name, node role, target hop, topology, scenario, optional
   trial timeout, dan notes. Forwarding mode dibaca dari build config, bukan
   input manual.
3. Tekan `START SESSION`.
4. Tekan `START TRIAL`.
5. Jalankan eksperimen fisik.
6. Pantau LIVE, METRICS, EVENTS, dan SYSTEM.
7. Akhiri trial sebagai `SUCCESS`, `FAILED` dengan failure reason, atau
   `INVALID`.
8. Gunakan `NEXT TRIAL` hanya setelah trial berjalan sudah terminal.
9. Export current trial CSV, session CSV, atau session JSON.

Trial invalid tidak dihapus. Trial tetap tersimpan dengan status `INVALID`
agar keputusan eksperimen bisa diaudit. Trial timeout hanya menandai trial
`FAILED/TIMEOUT` saat monitor aktif; ini bukan TTL protokol mesh.

Session logging dipisah menjadi `RESEARCH` dan `AUTO`. Research Monitor hanya
menampilkan session `RESEARCH` yang masih aktif. Event service/background tetap
dicatat ke session `AUTO` ketika tidak ada session penelitian aktif.

## Timestamp

Protocol timestamp adalah timestamp ringkas satu detik di payload BLE. Timestamp
ini dipakai untuk identity packet, state SOS, dan ACK tombstone. Kolom
`protocol_timestamp_ms` hanya berisi timestamp protokol, bukan waktu event.

Research event time disimpan terpisah sebagai `event_timestamp_ms`. Untuk
packet BLE yang diterima native, nilai ini berasal dari timestamp native receive,
bukan waktu drain Dart. Jika tersedia, `elapsed_realtime_ms` dipakai untuk
latency lokal agar tidak terpengaruh perubahan jam sistem.

## Metric Scope

Metric pada layar ini bersifat `LOCAL DEVICE` atau `CURRENT SESSION` kecuali ada
log peer yang sudah digabungkan secara eksplisit. Nilai network-wide tidak boleh
dibuat dari asumsi.

## Formulas

DSR:

```text
successful valid trials
-----------------------
total explicit SUCCESS + FAILED trials
x 100%
```

Trial `INVALID`, `RUNNING`, dan `COMPLETED` tanpa result eksplisit tidak masuk
denominator.

Duplicate Ratio:

```text
duplicate receptions
------------------------------
BLE_PACKET_ACCEPTED + duplicate receptions
x 100%
```

Accepted count berasal hanya dari event canonical `BLE_PACKET_ACCEPTED`.
Diagnostic stored/queued events tidak menambah accepted count. Stale packet
tidak dihitung sebagai duplicate.

Local Relay Processing Latency:

```text
BLE_RELAY_STARTED timestamp
-
BLE_PACKET_RECEIVED timestamp
```

Ini hanya aman untuk event pada device yang sama dan dikorelasikan dengan
`payload_hash`, bukan hanya sender CRC.

Hop Correctness:

```text
hop_out = min(hop_in + 1, 63)
```

`63 -> 63` adalah PASS.

Transmission Overhead:

```text
successful transmission starts
------------------------------
successful valid trials
```

Jika tidak ada successful valid trial, nilai ditampilkan sebagai `N/A`.

## E2E Latency

End-to-end latency hanya boleh dihitung saat data berisi event source dan
destination yang valid dari log tersinkron/tergabung:

```text
destination_first_receive_timestamp
-
source_first_advertise_timestamp
```

Jika bukti peer tidak ada, Research Monitor menampilkan `Requires peer log`.
Jangan menghitung E2E dari clock device yang tidak disinkronkan.

## RSSI dan Hop

RSSI ditampilkan sebagai statistik observasional: count, min, mean, median, dan
max. RSSI hanya diambil dari `BLE_PACKET_RECEIVED` dan tidak dikonversi langsung
menjadi meter.

Hop dipisah menjadi `hop_in` dan `hop_out`. Current Packet di LIVE membangun
snapshot dari RX terbaru dan event output dengan `payload_hash` yang sama.

## ACK Metrics

ACK metrics memisahkan:

- ACK received
- ACK accepted
- ACK duplicate
- ACK stale
- ACK invalid

ACK packet dan SOS terminal state tetap diperlakukan sesuai semantik P8.
Relay lokal yang berhenti karena ACK dicatat dengan event produksi
`SOS_RELAY_TERMINATED_BY_ACK`, lalu dipasangkan deterministik dengan
`ACK_RECEIVED` lewat `payload_hash`.

## Device Metadata

Session menyimpan manufacturer, model, Android release, SDK, app versionName,
versionCode, dan build ID dari `RESQMESH_BUILD_ID` jika ada. Metadata ini tampil
di tab SYSTEM dan ikut CSV/JSON export.

## Export

CSV dan JSON export berisi session metadata, trial metadata, dan raw events.
Calculated metrics harus bisa direproduksi dari raw events.

Kolom CSV stabil mencakup session kind, session/trial identifiers, trial result,
failure reason, device metadata, node role, forwarding mode, target hop,
`event_timestamp_ms`, ISO event time, `elapsed_realtime_ms`,
`protocol_timestamp_ms`, event type, sender CRC, packet type, status, hop in,
hop out, RSSI, payload hash, queue fields jika tersedia, dan detail.

## Limitations

- Trial ID tidak dikirim lewat BLE; semua node eksperimen harus mengisi session
  code/trial number secara manual untuk korelasi log.
- Network-wide metric membutuhkan merged peer logs.
- Research timeout hanya boleh dipakai untuk keputusan trial, bukan TTL protocol.
- Physical test A-K tetap `NOT RUN` sampai ada bukti perangkat fisik.
