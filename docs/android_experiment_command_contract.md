# Android Experiment Command Contract

Antarmuka ini hanya tersedia pada build `debug`. Receiver tidak dimasukkan ke
manifest produksi. Hasil final ditulis sebagai satu baris log:

```text
RESQMESH_CMD_RESULT {"ok":true,...}
```

Pantau hasil dengan:

```powershell
adb logcat -s ResQMeshCommand:I
```

Semua command mutasi wajib memiliki `command_id` unik. Pengulangan
`command_id` yang sama mengembalikan hasil tersimpan dan tidak mengulang efek.

## Configure Session

```powershell
adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command configure_session --es command_id cfg-001 --es session_id session-h2-001 --es session_code TRICKLE-H2 --es node_id phone-a --es role SOURCE --ei target_hop 2 --es hypothesis H2 --ei observation_window_ms 60000 --es mode trickle --es build_id local-debug --ei expected_hop_in 1 --ei hop_out 2 --ei node_layer 0 --ei rx_burst_gap_ms 2400
```

`mode` menerima `trickle`, `basic`, atau `basic_flooding`. Peran menerima
`SOURCE`, `RELAY`, `DESTINATION`, `GATEWAY`, atau `OBSERVER`. Sesi eksperimen
utama selalu memaksa gateway dan ACK nonaktif. Untuk validasi terpisah gunakan
`--ez main_experiment false` dan aktifkan secara eksplisit dengan
`--ez gateway_enabled true --ez ack_enabled true`.

## Trial Lifecycle

```powershell
adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command start_trial --es command_id start-001 --es session_id session-h2-001 --es trial_id trial-h2-001 --es trial_code H2-T001

adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command trigger_sos --es command_id trigger-001 --es trial_id trial-h2-001 --es node_id phone-a --ef latitude 3.5952 --ef longitude 98.6722

adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command end_observation_window --es command_id window-end-001 --es trial_id trial-h2-001

adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command finalize_trial --es command_id finalize-001 --es trial_id trial-h2-001 --es result SUCCESS

adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command export_trial --es command_id export-001 --es session_id session-h2-001 --es trial_id trial-h2-001

adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command reset_trial --es command_id reset-001 --es trial_id trial-h2-001
```

`trigger_sos` membuat tepat satu logical SOS per trial dengan hop awal 1.
`end_observation_window` hanya mengubah trial menjadi `WINDOW_ENDED`; hasil
akhir ditetapkan pengendali dengan `SUCCESS`, `FAILED_DELIVERY`, atau `INVALID`.
`reset_trial` menghapus state protokol trial tetapi mempertahankan event arsip.

## Readiness

```powershell
adb shell am broadcast -a id.ac.usu.resqmesh.RESEARCH_COMMAND -n id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver --es command readiness
```

Respons memuat status Bluetooth, izin scan/advertise, scanner, advertiser,
mode, session, trial, ukuran queue, error native terakhir, serta
`protocol_epoch` yang berisi ID, awal, akhir representasi, sisa hari, dan
validitas. `start_trial` dan `trigger_sos` gagal dengan
`PROTOCOL_EPOCH_OUT_OF_RANGE` jika epoch 24-bit sudah tidak valid.

