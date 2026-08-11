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
ini dipakai untuk identity packet, state ordering, logical packet/state
correlation, SOS version matching, dan ACK tombstone. Kolom
`protocol_timestamp_ms` hanya berisi timestamp protokol, bukan waktu event dan
bukan clock untuk latency sub-detik.

Research event time disimpan terpisah sebagai `event_timestamp_ms`. Untuk
packet BLE yang diterima native, nilai ini berasal dari timestamp native receive,
bukan waktu drain Dart.

LOCAL SAME DEVICE:

```text
Jika start dan end sama-sama punya elapsed_realtime_ms:
  latency = end.elapsed_realtime_ms - start.elapsed_realtime_ms

Jika salah satu tidak punya elapsed_realtime_ms:
  latency = end.event_timestamp_ms - start.event_timestamp_ms
```

Never mix clock domains. Jangan pernah mengurangi wall-clock dengan
`elapsed_realtime_ms`, atau sebaliknya.

CROSS DEVICE:

```text
E2E latency = destination.event_timestamp_ms - source.event_timestamp_ms
```

Cross-device latency hanya memakai synchronized wall-clock research time.
`elapsed_realtime_ms` tidak boleh dipakai antarperangkat karena origin-nya
berbeda untuk setiap Android device.

## Metric Scope

Metric pada layar ini bersifat `CURRENT TRIAL / LOCAL DEVICE` atau
`CURRENT SESSION / LOCAL DEVICE` kecuali ada log peer yang sudah digabungkan
secara eksplisit. DSR tetap session-scoped walaupun ada trial aktif. Nilai
network-wide tidak boleh dibuat dari asumsi.

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

SOS Logical Duplicate Ratio:

```text
SOS BLE_PACKET_DUPLICATE
------------------------------
SOS BLE_PACKET_ACCEPTED + SOS BLE_PACKET_DUPLICATE
x 100%
```

Accepted count berasal hanya dari event canonical `BLE_PACKET_ACCEPTED` dengan
`packet_type = sos`. Diagnostic stored/queued events tidak menambah accepted
count. SOS stale packet tidak dihitung sebagai duplicate. SOS Logical Duplicate
Ratio hanya menghitung `BLE_PACKET_DUPLICATE` dengan `packet_type = sos` yang
mencapai ResQMesh forwarding policy. ACK duplicate dikeluarkan dari rasio ini
dan tetap tersedia sebagai metric `ACK Duplicate`. Exact repeated advertisements
yang sudah disaring oleh native receiver/inbox dedup tidak termasuk.

SOS Stale Received hanya menghitung `BLE_PACKET_STALE` dengan
`packet_type = sos`. ACK stale dikeluarkan dari packet count utama dan tetap
tersedia di bagian ACK Metrics sebagai `ACK Stale`.

Initial Local Relay Latency:

```text
first matching BLE_RELAY_STARTED timestamp
-
BLE_PACKET_ACCEPTED receive timestamp
```

Ini hanya aman untuk event pada device yang sama. Anchor-nya adalah accepted
radio receive yang benar-benar mengubah forwarding state, bukan setiap raw
`BLE_PACKET_RECEIVED`. Hanya relay pertama untuk logical packet key
(`packet_type`, `sender_crc`, `protocol_timestamp_ms`, dan `status`) yang
dihitung. Duplicate RX dan slot retransmission berikutnya tidak menambah sample
latency awal.

Hop Correctness:

```text
accepted hop_in -> first matching relay hop_out
expected hop_out = min(hop_in + 1, 63)
```

`63 -> 63` adalah PASS. Hop correctness tidak memakai duplicate raw RX karena
validasi ini mengukur state yang benar-benar diteruskan.

Local TX / Successful Trial:

```text
successful transmission starts
------------------------------
successful valid trials
```

Jika tidak ada successful valid trial, nilai ditampilkan sebagai `N/A`.
Ini adalah local-device transmission metric. Ini bukan total network-wide
transmission overhead. Network-wide overhead requires merged peer logs from all
participating nodes.

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

SOS RSSI ditampilkan sebagai statistik observasional: count, min, mean, median,
dan max. RSSI utama hanya diambil dari `BLE_PACKET_RECEIVED` dengan
`packet_type = sos` dan tidak dikonversi langsung menjadi meter. ACK RSSI tidak
masuk statistik propagasi SOS utama.

Hop dipisah menjadi `hop_in` dan `hop_out`. SOS Hop In sample deskriptif hanya
berasal dari `BLE_PACKET_RECEIVED` dengan `packet_type = sos`. SOS Hop Out
sample hanya berasal dari `BLE_RELAY_STARTED` dengan `packet_type = sos`. ACK
hop tetap terlihat di event/timeline, tetapi tidak masuk statistik hop utama
untuk forwarding SOS.

## Better-Hop Behavior

ResQMesh tetap memakai epidemic forwarding. Untuk equal sender/timestamp/status
state, packet dengan resulting stored hop yang lebih kecil diperlakukan sebagai
better-hop state update atau route-quality correction. Storage ordering final:

```text
protocol timestamp
-> status priority
-> lower resulting hop
```

Hop quality hanya dipakai saat timestamp dan status sama. Hop yang lebih baik
tidak boleh mengalahkan protocol state yang lebih baru, terminal status, atau
ACK tombstone. Ordering canonical ini dipakai oleh state handling yang
kompatibel dengan `ForwardingPolicy`, scheduling di `BleRelayService`,
persistence di `RelayQueueService`, dan preferred-state selection di
`DatabaseHelper`. Saat better-hop update diterima, SQLite dan relay queue
diperbarui agar relay berikutnya memakai hop yang lebih baik, dan relay
scheduling metrics direset agar state improvement segera eligible sesuai aturan
queue yang ada.

Current Packet di LIVE membangun snapshot dari latest accepted logical
forwarding lifecycle, bukan dari raw duplicate advertisement terbaru. Anchor-nya
adalah `BLE_PACKET_ACCEPTED`, lalu `BLE_PACKET_STORED`, `BLE_RELAY_QUEUED`, dan
first matching `BLE_RELAY_STARTED` hanya ditempel jika timestamp-nya sama atau
lebih baru dari accepted RX. Jika belum ada relay setelah accepted RX, `Hop Out`
dan `Advertised At` ditampilkan kosong.

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
`ACK_RECEIVED` lewat logical ACK key (`sender_crc`, `protocol_timestamp_ms`,
dan `status`). Event termination dicatat saat matching local SOS forwarding
sudah terkonfirmasi berhenti/tersuppressed, sebelum menunggu startup ACK
advertising. Duplicate ACK tidak boleh membuat sample termination kedua.

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
