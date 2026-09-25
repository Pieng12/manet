# ResQMesh ESP32-C3 Firmware

Satu firmware ini dipakai untuk seluruh ESP32-C3. Role, layer, mode, session,
trial, dan identitas node dikirim sebagai JSON satu baris melalui serial 115200
baud dan disimpan di NVS. Jangan membuat varian source per perangkat.

## Build dan Flash

```powershell
cd firmware/esp32c3
py -m pip install platformio
py -m platformio test -e native
py -m platformio run -e esp32c3
py -m platformio run -e esp32c3 -t upload --upload-port COM3
py -m platformio device monitor -b 115200 -p COM3
```

Firmware memakai NimBLE legacy `ADV_NONCONN_IND`, sehingga advertising tidak
connectable dan tidak scannable. Raw manufacturer AD membawa company ID
`FF FF`, diikuti application payload ResQMesh tepat 17 byte. Codec menerima
17 byte application payload atau 19 byte manufacturer data lalu memisahkan
company ID secara eksplisit.

## Konstanta Protokol

- Epoch ID: `resqmesh-2026-06-01`
- Epoch awal: `1780272000` detik UTC
- Manufacturer ID: `0xFFFF`
- Payload: 17 byte
- Hop relay: `min(hopIn + 1, 63)`
- Trickle: `Imin=8 s`, `Imax=256 s`, `k=1`, `t` pada `[I/2, I)`
- Basic: burst 2 s, interval 2 s dari akhir burst, jitter 300-1500 ms

Tidak ada nearest-window reconstruction. `start_trial` dan `trigger_sos`
gagal dengan `PROTOCOL_EPOCH_OUT_OF_RANGE` jika clock berada di luar rentang
24-bit.

## Serial JSON

Setiap command dan respons adalah satu objek JSON per baris. Contoh minimum:

```json
{"command":"clock_sync","command_id":"clock-1","wall_time_ms":1784000000000}
{"command":"configure_session","command_id":"cfg-1","node_id":"esp-r1","build_id":"build-1","session_id":"s1","role":"RELAY","mode":"trickle","hypothesis":"H2","node_layer":1,"expected_hop_in":1,"protocol_active":true,"protocol_epoch_id":"resqmesh-2026-06-01","protocol_epoch_seconds":1780272000}
{"command":"start_trial","command_id":"start-1","trial_id":"t1"}
{"command":"readiness","command_id":"ready-1"}
{"command":"reset_trial","command_id":"reset-1","trial_id":"t1"}
```

Source juga menerima `trigger_sos` dengan `latitude` dan `longitude`. Event
keluar sebagai JSON dengan `kind=event`; respons command memakai
`kind=response`. Event radio mencakup receive, accepted, duplicate, topology
ignored, interval/suppression Trickle, burst requested/started/ended/failed,
relay started, dan destination first receive.

NVS menyimpan konfigurasi dan packet aktif. Restart memulihkan packet dan
mereset interval Trickle ke `Imin`, sesuai perubahan domain monotonic.
