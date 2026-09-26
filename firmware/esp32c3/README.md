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

Board native USB Espressif memakai VID:PID `303A:1001`. Konfigurasi PlatformIO
menetapkan `ARDUINO_USB_MODE=1`, `ARDUINO_USB_CDC_ON_BOOT=1`, serta DTR/RTS nol.
Nomor COM dapat berubah setelah upload. Firmware tidak menunggu serial monitor
dan command `readiness` dapat dikirim kapan saja setelah boot.

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
- Protocol version: `resqmesh-ble17-v1`
- Hop relay: `min(hopIn + 1, 63)`
- Trickle: `Imin=8 s`, `Imax=256 s`, `k=1`, `t` pada `[I/2, I)`
- Basic: burst 2 s, interval 2 s dari akhir burst, jitter 300-1500 ms
- RX burst inactivity gap awal: `1000 ms` (dikirim melalui `configure_session`)

Tidak ada nearest-window reconstruction. `start_trial` dan `trigger_sos`
gagal dengan `PROTOCOL_EPOCH_OUT_OF_RANGE` jika clock berada di luar rentang
24-bit.

## Serial JSON

Setiap command dan respons adalah satu objek JSON per baris. Contoh minimum:

```json
{"command":"clock_sync","command_id":"clock-1","wall_time_ms":1784000000000}
{"command":"configure_session","command_id":"cfg-1","node_id":"esp-r1a","build_id":"session-label","session_id":"s1","role":"RELAY","mode":"trickle","hypothesis":"H2","node_layer":1,"expected_hop_in":1,"hop_out":2,"rx_burst_gap_ms":1000,"protocol_active":true,"protocol_version":"resqmesh-ble17-v1","protocol_epoch_id":"resqmesh-2026-06-01","protocol_epoch_seconds":1780272000}
{"command":"start_trial","command_id":"start-1","trial_id":"t1"}
{"command":"readiness","command_id":"ready-1"}
{"command":"reset_trial","command_id":"reset-1","trial_id":"t1"}
```

Source juga menerima `trigger_sos` dengan `latitude` dan `longitude`. Event
keluar sebagai JSON dengan `kind=event`; respons command memakai
`kind=response`. Event radio mencakup receive, accepted, duplicate, topology
ignored, interval/suppression Trickle, burst requested/started/ended/failed,
relay started, dan destination first receive.

`firmware_build_id` pada readiness berasal dari SHA commit pendek yang
disuntikkan otomatis oleh `build_id.py` saat PlatformIO membangun binary dan
tidak berubah saat `configure_session`. Field `build_id` command hanya menjadi
`session_label`. Untuk eksperimen penelitian, APK dan firmware harus dibangun
dari commit yang sama dan readiness harus melaporkan build ID yang sama persis.

NVS menyimpan konfigurasi dan packet aktif. Restart memulihkan packet dan
mereset interval Trickle ke `Imin`, sesuai perubahan domain monotonic.
