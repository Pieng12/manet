# ResQMesh Research Monitor

Research Monitor adalah layar debug untuk eksperimen skripsi. Layar ini
mempermudah pembuatan session, penomoran trial, pemantauan BLE/relay, metrik
lokal, timeline event, dan export data mentah. Fitur ini bukan layar pengguna
darurat normal.

Research metadata disimpan di SQLite. Metadata session/trial tidak pernah
dimasukkan ke payload BLE 17 byte.

## Workflow

1. Buka `Research Monitor`.
2. Isi experiment name, forwarding mode, node role, target hop, topology,
   scenario, dan notes.
3. Tekan `START SESSION`.
4. Tekan `START TRIAL`.
5. Jalankan eksperimen fisik.
6. Pantau LIVE, METRICS, EVENTS, dan SYSTEM.
7. Akhiri trial sebagai `SUCCESS`, `FAILED`, atau `INVALID`.
8. Gunakan `NEXT TRIAL` sampai jumlah pengulangan selesai.
9. Export current trial CSV, session CSV, atau session JSON.

Trial invalid tidak dihapus. Trial tetap tersimpan dengan status `INVALID`
agar keputusan eksperimen bisa diaudit.

## Timestamp

Protocol timestamp adalah timestamp ringkas satu detik di payload BLE. Timestamp
ini dipakai untuk identity packet, state SOS, dan ACK tombstone.

Research event time disimpan terpisah sebagai `event_timestamp_ms`. Nilai ini
dipakai untuk metrik lokal seperti RX ke relay start. Jangan memasukkan
timestamp millisecond ke payload BLE.

## Metric Scope

Metric pada layar ini bersifat `LOCAL DEVICE` atau `CURRENT SESSION` kecuali ada
log peer yang sudah digabungkan secara eksplisit. Nilai network-wide tidak boleh
dibuat dari asumsi.

## Formulas

DSR:

```text
successful valid trials
-----------------------
total valid completed trials
x 100%
```

Trial `INVALID` tidak masuk denominator.

Duplicate Ratio:

```text
duplicate receptions
------------------------------
accepted + duplicate receptions
x 100%
```

Stale packet tidak dihitung sebagai duplicate.

Local Relay Processing Latency:

```text
BLE_ADVERTISE_STARTED timestamp
-
BLE_PACKET_RECEIVED timestamp
```

Ini hanya aman untuk event pada device yang sama.

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

## RSSI

RSSI ditampilkan sebagai statistik observasional: count, min, mean, median, dan
max. RSSI tidak dikonversi langsung menjadi meter.

## ACK Metrics

ACK metrics memisahkan:

- ACK received
- ACK accepted
- ACK duplicate
- ACK stale
- ACK invalid

ACK packet dan SOS terminal state tetap diperlakukan sesuai semantik P8.

## Export

CSV dan JSON export berisi session metadata, trial metadata, dan raw events.
Calculated metrics harus bisa direproduksi dari raw events.

Kolom CSV stabil mencakup session/trial identifiers, node role, forwarding mode,
target hop, event timestamp, event type, sender CRC, protocol timestamp, packet
type, status, hop, RSSI, payload hash, queue fields jika tersedia, dan detail.

## Limitations

- Trial ID tidak dikirim lewat BLE; semua node eksperimen harus mengisi session
  code/trial number secara manual untuk korelasi log.
- Network-wide metric membutuhkan merged peer logs.
- Research timeout hanya boleh dipakai untuk keputusan trial, bukan TTL protocol.
- Physical test A-K tetap `NOT RUN` sampai ada bukti perangkat fisik.
