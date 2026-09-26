# Cross-Node Log Format

Android dan ESP32 diekspor sebagai JSON event. Field canonical yang dipakai
merger adalah `event_type`, `node_id`/`device_id`, `session_id`, `trial_id`,
`mode`, `hypothesis`, `timestamp_ms`, `monotonic_ms` atau
`elapsed_realtime_ms`, `message_key`, `state_identity`, `observation_id`,
`event_key`, `burst_id`, `packet_type`, `status`, `hop_in`, `hop_out`, dan RSSI.
Merger hanya menerima event yang cocok dengan `session_id` dan `trial_id`
manifest. Event tanpa trial, event trial lama, node tujuan yang salah, message
key berbeda, dan hop yang tidak sesuai tidak boleh memengaruhi metrik.

Aturan hitung:

- DSR = `SUCCESS / (SUCCESS + FAILED_DELIVERY)`; `INVALID` dikeluarkan.
- E2E = `DESTINATION_FIRST_VALID_RECEIVE - SOURCE_FIRST_ADVERTISE_STARTED`
  untuk message key yang sama dan hanya jika clock sync valid.
- LDR = `N_duplicate / (N_accepted + N_duplicate)`; penyebut nol menghasilkan
  null.
- Network-wide overhead = jumlah burst SOS unik yang benar-benar menghasilkan
  `ADVERTISE_BURST_STARTED` pada semua node / jumlah trial valid. Trial gagal
  delivery tetap berada dalam penyebut.

`ADVERTISE_BURST_REQUESTED` bukan TX sukses. Event started dideduplikasi per
node dan burst ID. Event RX canonical dideduplikasi per node dan event key atau
observation ID. RSSI hanya berasal dari receive, dan hop output hanya berasal
dari relay/advertise yang benar-benar dimulai.

`attempt_summary.csv` memuat semua attempt terminal termasuk `INVALID`.
`INVALID` tidak masuk penyebut DSR; `SUCCESS` dan `FAILED_DELIVERY` masuk.
