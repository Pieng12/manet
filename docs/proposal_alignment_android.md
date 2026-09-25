# Android Proposal Alignment

Dokumen ini mencatat keputusan Android untuk proposal "Pengendalian
Retransmisi Redundan pada Komunikasi SOS Multi-Hop Berbasis Bluetooth Low
Energy Menggunakan Algoritma Trickle".

## Protokol dan Identitas

- Payload tetap legacy manufacturer data `0xFFFF`, tepat 17 byte, big-endian.
- Koordinat adalah integer signed 24-bit two's complement dengan skala 10.000.
- Sumber mengiklankan hop 1; relay memakai `min(hop_in + 1, 63)`. Nilai 63
  hanya saturasi representasi, bukan TTL.
- `MessageKey = sender_crc + protocol_timestamp`. Timestamp ini immutable.
- `StateIdentity` menambahkan status, ACK, dan flag server. `observation_id`
  tetap identitas penerimaan fisik dan tidak menjadi message key.
- Epoch protokol adalah konfigurasi eksplisit dan disimpan bersama ID epoch.
  Nilai 24-bit divalidasi tanpa rekonstruksi nearest-window.
- Tombstone ACK menggunakan `(sender_crc, protocol_timestamp)`, sehingga ACK
  lama tidak mematikan SOS baru dari sumber yang sama.

## Scheduler

Parameter proposal adalah Trickle `Imin=8 s`, `Imax=256 s`, `m=5`, `k=1`,
burst 2 s, serta jitter 300-1500 ms. Basic Flooding dijadwalkan dari akhir
burst: `burst_end + 2 s + jitter`. Trickle memilih `t` pada `[I/2, I)` dan
suppression hanya menahan kesempatan pada interval berjalan.

Interval menggunakan clock monotonic. Wall clock hanya untuk korelasi
antarnode. Domain monotonic yang berubah saat proses/perangkat restart mereset
state Trickle ke `Imin` dan mencatat alasan. Mode forwarding disimpan pada sesi,
dimuat ulang oleh isolate background, dan menjadi sumber konfigurasi semua
instance queue yang tidak memiliki override test eksplisit. Hanya isolate
background service yang memiliki scheduler; worker inbox meminta scheduler
tick dan tidak mengambil alih advertiser.

## Trial dan Topologi

Satu trial memiliki satu logical SOS dan ID eksternal yang sama pada semua
node. Command ADB bersifat idempotent berdasarkan `command_id`. Timeout hanya
mengakhiri observation window dan menghasilkan `PENDING_EVALUATION` sampai log
tujuan digabungkan.

Topology policy dijalankan sebelum mutasi message state, LDR, atau counter
Trickle. Paket dari hop/advertiser yang tidak sesuai dicatat sebagai
`TOPOLOGY_IGNORED`. Destination menerima dan mencatat penerimaan valid pertama
tanpa memasukkan SOS ke relay queue. RSSI hanya metrik observasional.

## Burst dan Metrik

Advertising eksperimen selalu legacy, non-connectable, dan non-scannable.
Satu callback start native yang sukses menghasilkan satu burst transmission.
Setiap burst memiliki `burst_id` dan event requested/started/ended/failed.
Penerimaan memakai `ScanResult.timestampNanos`, kemudian dipetakan ke wall
clock saat callback. Ambang RX burst tersimpan sebagai `rx_burst_gap_ms` pada
sesi dan diteruskan ke native shared preferences; 5000 ms hanya default.

Formula analisis:

- DSR = `SUCCESS / (SUCCESS + FAILED_DELIVERY)`; `INVALID` dikeluarkan.
- E2E = `DESTINATION_FIRST_VALID_RECEIVE - SOURCE_FIRST_ADVERTISE_STARTED`
  hanya untuk sinkronisasi clock valid.
- LDR = `N_dup / (N_acc + N_dup)` dan undefined bila penyebut nol.
- Overhead = jumlah burst SOS yang berhasil dimulai dibagi seluruh trial valid,
  termasuk `FAILED_DELIVERY`.

Statistik numerik memuat count, min, max, mean, median, sample standard
deviation, Q1, Q3, dan IQR. Android menandai metrik lintas-node sebagai
`requiresMergedPeerLogs`; event mentah CSV/JSON tetap sumber kebenaran dan
agregasi akhir harus dikelompokkan berdasarkan mode serta H1/H2/H3 setelah log
semua node digabungkan.

## Gateway dan Kesiapan

Sesi eksperimen utama memaksa gateway dan ACK nonaktif. Upaya gateway/ACK
dicatat sebagai pelanggaran konfigurasi. Validasi gateway/ACK harus memakai
sesi terpisah dan endpoint lokal/konfigurabel.

Unit test, analyzer, build APK, dan test JVM tidak menggantikan validasi radio.
Uji perangkat fisik tetap **NOT RUN** sampai ada bukti dari perangkat. Kesiapan
penelitian final masih menunggu integrasi firmware ESP32-C3, pengendali
komputer, penggabungan log lintas-node, dan validasi fisik.

