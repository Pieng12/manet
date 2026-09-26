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
  untuk source, destination, message key, hop, session, dan trial yang sama,
  hanya jika clock sync valid dan hasilnya tidak melebihi
  `observation_window_ms + clock_tolerance_ms` dari manifest.
- LDR = `N_duplicate / (N_accepted + N_duplicate)`; penyebut nol menghasilkan
  null.
- Network-wide overhead = jumlah burst SOS unik yang benar-benar menghasilkan
  `ADVERTISE_BURST_STARTED` pada semua node / jumlah trial valid. Trial gagal
  delivery tetap berada dalam penyebut.

`ADVERTISE_BURST_REQUESTED` bukan TX sukses. Semua identitas deduplikasi selalu
menyertakan session, trial, node, dan event type. Event started kemudian memakai
burst ID, sedangkan event RX memakai event key atau observation ID. Hanya
salinan event yang benar-benar identik yang digabung; burst atau observation ID
yang sama pada trial berbeda tetap merupakan event berbeda. RSSI hanya berasal
dari receive, dan hop output hanya berasal dari relay/advertise yang benar-benar
dimulai.

Manifest trial wajib menyimpan observation window, clock tolerance, source,
destination, expected hop, session, trial, dan message key. Nilai hilang/tidak
valid atau mismatch antara evidence controller dan rekonstruksi raw log membuat
trial `INVALID`.

`attempt_summary.csv` memuat semua attempt terminal termasuk `INVALID`.
`INVALID` tidak masuk penyebut DSR; `SUCCESS` dan `FAILED_DELIVERY` masuk.
