# ResQMesh Experiment Controller

Controller mengatur satu Android dan lima ESP32-C3 melalui ADB dan serial JSON.
Satu firmware yang sama digunakan pada seluruh ESP32; role dan topology H1-H3
dikirim saat `configure_session`.

## Persiapan Windows

```powershell
flutter doctor -v
py -m pip install -r tools/experiment_controller/requirements.txt
flutter pub get
$BuildId = (git rev-parse --short=12 HEAD).Trim()
flutter build apk --debug --dart-define=RESQMESH_BUILD_ID=$BuildId
adb install -r build/app/outputs/flutter-apk/app-debug.apk
Copy-Item tools/experiment_controller/config.example.json experiment.local.json
```

Isi `android_build_id` dan `firmware_build_id` pada `experiment.local.json`
dengan nilai `$BuildId` yang sama. Placeholder, nilai generik, SHA berbeda,
atau SHA kurang dari 12 karakter ditolak. PlatformIO menyuntikkan SHA pendek
dari commit aktif ke firmware secara otomatis saat build.
`rx_burst_gap_ms` wajib positif dan nilai awal `1000` diteruskan ke seluruh
node, diperiksa saat readiness, serta dicatat pada fingerprint dan manifest.

Aktifkan Bluetooth dan izin scan/advertise pada Android. Flash firmware yang
sama ke R1A, R1B, R2A, R2B, dan Destination. Native USB ESP32-C3 memakai
VID:PID `303A:1001`; nomor COM dapat berubah setelah flashing dan harus diisi
manual pada `experiment.local.json`.

Uji satu board sebelum melanjutkan:

```powershell
cd firmware\esp32c3
py -m platformio run -e esp32c3 -t upload --upload-port COM_YANG_BENAR
py -m platformio device monitor --port COM_YANG_BENAR --baud 115200
```

Kirim satu baris JSON berikut. Serial monitor tidak diperlukan saat controller
beroperasi.

```json
{"command":"readiness","command_id":"test-1"}
```

## Urutan Pengujian

```powershell
py tools/experiment_controller/run.py discover
py tools/experiment_controller/run.py readiness --config experiment.local.json
py tools/experiment_controller/run.py smoke --config experiment.local.json --output experiment_output
Get-Content experiment_output/smoke_report.json
py tools/experiment_controller/run.py run --config experiment.local.json --output experiment_output
py tools/experiment_controller/run.py merge --input experiment_output/raw --manifest experiment_output/manifest.json --output experiment_output/merged
```

`smoke` menjalankan tepat enam kondisi: Trickle H1-H3 dan Basic Flooding H1-H3.
Batch menolak berjalan jika `smoke_report.json` gagal atau fingerprint
build/config/topology berbeda. Override darurat harus eksplisit:

```powershell
py tools/experiment_controller/run.py run --config experiment.local.json --output experiment_output --force-without-smoke
```

Target batch adalah `valid_trials_per_condition`, bukan jumlah attempt.
`SUCCESS` dan `FAILED_DELIVERY` valid untuk DSR; `INVALID` disimpan tetapi
diganti attempt baru sampai target atau `max_attempts_per_condition` tercapai.
Resume tidak memicu ulang attempt terminal dan memakai urutan/seed dari
manifest.

Output merger:

- `events.json` dan `events.csv`
- `trial_summary.csv`
- `aggregate_by_mode_hop.csv`
- `invalid_trials.csv`
- `attempt_summary.csv`

Output smoke adalah `smoke_report.json` dan `smoke_report.csv`. Raw log setiap
attempt hanya berisi event dengan `session_id`, `trial_id`, dan node yang cocok.
Event diagnostic yang ditolak disimpan terpisah di `diagnostics`.

## Status Verifikasi

- `CODE VERIFIED`: hanya setelah test source lulus.
- `BUILD VERIFIED`: hanya setelah APK, native Android, dan firmware dibangun.
- `DEVICE SERIAL VERIFIED`: readiness serial telah dibuktikan pengguna.
- `DEVICE SMOKE TEST NOT RUN`: smoke enam kondisi belum dijalankan pada device.
- `PHYSICAL MULTI-HOP NOT RUN`: H1-H3 fisik belum dijalankan.
