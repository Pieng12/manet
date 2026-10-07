# Panduan Windows Profil Tetangga

Kerjakan hanya pada branch `metode-penerimaan`. APK dan firmware baru diperlukan.
Tidak ada flash, trial fisik, commit/push, atau penghapusan data oleh implementasi.
Pastikan semua Serial Monitor ditutup dan keenam perangkat tetap tersambung;
laptop jangan sleep. Jangan jalankan controller dan terminal serial bersamaan.

## 1. Periksa Toolchain Dan Build

```powershell
Set-Location D:\PKM\Project\pkmproject
git branch --show-current
git status --short
flutter --version
py --version
py -m pip install -r tools\experiment_controller\requirements.txt
py -m platformio --version
adb devices
py tools\experiment_controller\run.py discover
# Hanya jika memakai cache PlatformIO D:\pio yang sudah tersedia:
$env:PLATFORMIO_CORE_DIR = 'D:\pio'
```

Jangan mengganti config pribadi lama. Jangan `git clean`, erase_flash, clear data,
atau uninstall APK: instalasi `-r` mempertahankan database. Jika ada trial lama
aktif, selesaikan/invalidate dan arsipkan secara eksplisit dahulu; readiness tidak
otomatis menghapus hasilnya.

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
Push-Location android
.\gradlew.bat testDebugUnitTest
Pop-Location
$env:PYTHONPATH = 'tools\experiment_controller'
py -m unittest discover -s tools\experiment_controller\tests
py -m platformio test -d firmware/esp32c3 -e native
$Build = & .\tools\build_neighbor.ps1 -FingerprintOnly
$BuildId = $Build.build_id
& .\tools\build_neighbor.ps1
if ($LASTEXITCODE -ne 0) { throw 'Periksa build; jangan flash artifact gagal' }
```

Script membuat APK dan firmware dengan build ID identik, lalu salinan artifact
dan manifest source di `build/neighbor-<id>-<waktu>/`. Source berubah saat build
akan ditolak. Jangan mengedit source setelah build/config dikunci. Manifest
tersebut mencatat commit referensi dan hash isi working tree secara berbeda.

## 2. Instalasi Dan Flash Manual

Isi serial/port aktual dari discover, bukan nomor COM contoh:

```powershell
$Serial = 'ISI_ADB_SERIAL'
adb -s $Serial install -r build\app\outputs\flutter-apk\app-debug.apk
if ($LASTEXITCODE -ne 0) { throw 'Install APK gagal' }
adb -s $Serial shell am start -n id.ac.usu.resqmesh/.MainActivity
$env:RESQMESH_BUILD_ID = $BuildId
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port COM_A
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port COM_B
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port COM_C
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port COM_D
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port COM_E
Remove-Item Env:\RESQMESH_BUILD_ID
```

Periksa exit code **setiap** upload; jangan lanjut jika gagal. Flash tidak memakai
erase_flash. Aktifkan Bluetooth, izin scan/advertise, service relay/background dan
offline pada HP. Power/radio tetap sesuai source; S8 tidak boleh diklaim terkunci.

## 3. Konfigurasi Pilot

Gunakan file baru dan folder baru; jangan menimpa smoke/90/135/Uji Jarak.

```powershell
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ConfigPath = "experiment.neighbor.pilot.$Stamp.local.json"
Copy-Item tools\experiment_controller\config.neighbor.full.example.json $ConfigPath
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Config.session_id = "neighbor-pilot-$Stamp"
$Config.android_build_id = $BuildId
$Config.firmware_build_id = $BuildId
$Config.valid_trials_per_condition = 1
$Config.max_attempts_per_condition = 1
$Config.nodes[0].serial = $Serial
$Config.nodes[1].port = 'ISI_COM_A'
$Config.nodes[2].port = 'ISI_COM_B'
$Config.nodes[3].port = 'ISI_COM_C'
$Config.nodes[4].port = 'ISI_COM_D'
$Config.nodes[5].port = 'ISI_COM_E'
$Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
$OutputDir = Join-Path (Get-Location) "experiment_output\neighbor-pilot-$Stamp"
py tools\experiment_controller\run.py plan --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Plan gagal' }
py tools\experiment_controller\run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal; jangan mulai' }
py tools\experiment_controller\run.py smoke --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Smoke instrumentasi gagal; periksa raw/Invalid Trials' }
Start-Process explorer.exe -ArgumentList (Join-Path $OutputDir 'smoke_merged')
```

Full smoke adalah 12 kombinasi, main-only smoke empat. Workbook:
`smoke_merged/resqmesh_neighbor_analysis.xlsx`; raw di `smoke_run/raw/`.
FAILED_DELIVERY sah **bukan** alasan mengulang baseline sampai SUCCESS.
INVALID, source start gagal, serial putus, clock terlalu tidak pasti, atau reset
gagal wajib diperiksa. Jangan mengubah dataset agar tampak berhasil.

Pilot dipakai menentukan window/delay/recovery yang cukup, menguji empty STATUS,
HAVE+MISSING, actual OFF/ON, initial failure, dan margin STATUS/DATA. Default
180/30/120 detik bukan jaminan. Jika parameter/build berubah, folder dan smoke
baru wajib; jangan memakai smoke fingerprint lama.

## 4. Bekukan Dan Jalankan 60 Atau 180 Trial

Setelah pilot diterima, pilih **main** (S0, 60) atau **full** (180 dengan dua
skenario pendukung). Copy config pilot yang sudah benar ke file baru, isi ulang
session_id dan jumlah pengulangan. Untuk main set scenarios hanya S0_MAIN.

```powershell
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Frozen = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Frozen.session_id = "neighbor-main-$Stamp"
$Frozen.valid_trials_per_condition = 15
$Frozen.max_attempts_per_condition = 45
$Frozen.scenarios = @('S0_MAIN') # Full: @('S0_MAIN','S1_DELAYED_RX','S2_LATE_JOIN')
$ConfigPath = "experiment.neighbor.main.$Stamp.local.json"
$Frozen | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
$OutputDir = Join-Path (Get-Location) "experiment_output\neighbor-main-$Stamp"
py tools\experiment_controller\run.py plan --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Plan gagal' }
py tools\experiment_controller\run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal' }
py tools\experiment_controller\run.py smoke --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Smoke baru gagal' }
py tools\experiment_controller\run.py run --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Batch belum lengkap; periksa manifest dan jangan hapus raw' }
Start-Process explorer.exe -ArgumentList (Join-Path $OutputDir 'merged')
```

Urutan diacak dalam 15 blok (main empat kombinasi, full dua belas), seed dicatat.
Clock diperbarui setiap trial. Minimum pengamatan murni default main 3 jam/full
9 jam, belum termasuk Trickle awal/barrier/reset/smoke/INVALID; jangan memakai
estimasi lama 135 trial x 60 detik.

## 5. Resume, Jumlah Selesai, Dan Merge

Jika serial terputus, hentikan sesi dengan aman, pastikan radio berhenti, sambung
ulang perangkat dan periksa readiness. Jangan mengubah config/build/port sambil
melanjutkan folder fingerprint lama. Attempt terputus ditandai INVALID, raw
sebelumnya tidak ditimpa; valid FAILED_DELIVERY tidak dicoba ulang.

```powershell
$Manifest = Get-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Raw | ConvertFrom-Json
$Manifest.trials.PSObject.Properties.Value | Group-Object result | Select-Object Name,Count
py tools\experiment_controller\run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness belum pulih' }
py tools\experiment_controller\run.py run --config $ConfigPath --output $OutputDir
# Merge ulang ke folder BARU agar workbook sebelumnya tetap utuh:
$MergeDir = Join-Path $OutputDir ("merged-review-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
py tools\experiment_controller\run.py merge --input (Join-Path $OutputDir 'raw') --output $MergeDir --manifest (Join-Path $OutputDir 'manifest.json')
Start-Process explorer.exe -ArgumentList $MergeDir
```

Pisahkan analisis S0 dari S1/S2. Periksa tabel Receivers (lima baris per trial),
DSR/LDR/E2E/overhead DATA+CONTROL, setup sebelum t0, Participation, Invalid
Trials, dan All Events. Jangan menganggap suppression menjamin jaringan penuh,
atau Coded PHY membuktikan S8/jarak fisik tiga hop.

## 6. Validator Log Dan Kasus Pilot

Setelah smoke/pilot, jalankan pemeriksaan **tanpa koneksi perangkat** ke folder
baru. Jangan gunakan folder hasil lama sebagai tujuan:

```powershell
$CheckDir = Join-Path $OutputDir ("validation-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
py tools\experiment_controller\run.py validate-neighbor --input (Join-Path $OutputDir 'smoke_run\raw') --manifest (Join-Path $OutputDir 'smoke_run\manifest.json') --output $CheckDir
# Exit 0: semua kasus memiliki bukti PASS; 2: ada FAIL; 3: bukti INCONCLUSIVE.
# INCONCLUSIVE bukan gagal delivery dan bukan alasan menghapus/mengubah trial.
Start-Process explorer.exe -ArgumentList $CheckDir
```

Merge juga menyimpan hasil di `Log Validation`, JSON/CSV; PASS mengacu pada
kasus teramati dalam log, bukan sertifikat fisik universal. Fixture/mock diberi
label SYNTHETIC dan **tidak boleh dipakai sebagai penerimaan hardware**.

| Kasus pilot | Langkah dan bukti minimum |
| --- | --- |
| A melihat C HAVE, D MISSING | Pilot metode usulan, S1, D scanner OFF lalu ON sesuai controller. Cari snapshot keputusan A berisi ID C=HAVE dan D=MISSING, diikuti NEIGHBOR_TX_ALLOWED/FRESH_MISSING. Jika kombinasi tidak teramati, INCONCLUSIVE, bukan PASS. |
| Semua HAVE | Setelah propagasi S0, cari NEIGHBOR_TX_SUPPRESSED/ALL_OBSERVED_HAVE dengan have>0, missing=unknown=0 dan STATUS_BURST_STARTED berikutnya pada node sama. SOS tetap di queue/readiness. |
| Expiry | Dalam pilot terpisah hentikan TX/RX satu tetangga melalui set_node_participation, tunggu lebih dari freshness_ms, lalu cari NEIGHBOR_STATUS_EXPIRED dan snapshot peer UNKNOWN sebelum refresh. Jangan mengubah interval/freshness hanya untuk meluluskan batch. |
| Discovery kosong | S2: E TX/RX OFF sebelum SOS, kemudian ON. Cari STATUS_RECEIVED inventory_count=0, snapshot_complete=true, NEIGHBOR_DISCOVERED dan REPAIR_NEEDED dengan identitas burst yang sama pada D. Jika interval masih Imin/cooldown, tunggu kasus repair yang benar; REPAIR_DEFERRED_COOLDOWN bukan reset. |
| Scanner pulih | Untuk ENDED, FAILED, CANCELLED cari SCANNER_RECOVERY_CHECK terikat burst, rx_enabled=true, scanner_registered=true dan DATA_RECEIVED/STATUS_RECEIVED sesudahnya pada node sama. Registrasi API saja tidak membuktikan penerimaan RF pulih. Cancellation saat akhir window mungkin tak punya RX lanjutan: tetap INCONCLUSIVE. |
| S1 aktual | D: RX_PARTICIPATION_CHANGED confirmed_enabled=false, rx_enabled=false, scanner_registered=false; kemudian confirmed_enabled=true/rx_enabled=true. Command REQUESTED bukan bukti keberhasilan. |
| S2 aktual | E: NODE_PARTICIPATION_CHANGED OFF lalu ON, RX/TX keduanya berubah terkonfirmasi. Simpan event dan respons final command. |
| Native initial failure | Pilot terpisah: ganggu Bluetooth sumber saat initial pending, pulihkan dan arsipkan tanpa mengubah hasil. Wajib INITIAL_FORWARD_FAILED/first_forward_pending=true dan keberhasilan DATA berikutnya untuk inspeksi manual. Jika hanya blocked preflight atau gagal tidak terjadi, kasus native failure belum terbukti. Jangan memakai mock untuk menggantikannya. |
| Arsip/rumus | Keenam node harus memiliki marker TRIAL_WINDOW_STARTED/ENDED; event_sequence ESP tidak berlubang. Bandingkan hitung ulang M/N/U/R/TX/DSR/LDR/E2E dengan evidence manifest. Log parsial tidak boleh diberi PASS. |

Untuk command pilot manual, gunakan helper/transport controller yang membaca
respons final dan parameter `command_id` unik. Jangan membuka port serial kedua
saat controller berjalan. Perturbasi tambahan dilakukan hanya pada pilot
terpisah yang didokumentasikan, bukan pada batch utama/S1/S2 standar. Tandai
hasil pilot tersebut sebagai diagnostik; jangan gabungkan dengan dataset utama.

Periksa `Descriptive Statistics`, `Mechanism Diagnostics`, `PHY Evidence`,
`Charts` dan `setup_plus_window_tx`. Frekuensi diagnostik mencakup seluruh trial,
termasuk sebelum t0; nol event bukan bukti bahwa kasus sudah diuji. S0 tetap
terpisah dari S1/S2, statistik hanya trial valid termasuk FAILED_DELIVERY.
SD sampel kosong jika kurang dari dua nilai; delay tanpa RX bukan nol. Grafik
SVG dapat dibuka melalui folder `charts/` atau tautan di sheet Charts.

Contoh exporter tanpa perangkat, **data sintetis**, pada folder build baru:

```powershell
$Fixture = Join-Path 'build' ("neighbor-SYNTHETIC-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
py tools\neighbor_report_fixture.py --output $Fixture
Start-Process explorer.exe -ArgumentList (Join-Path (Get-Location) "$Fixture\merged")
```

Fixture sengaja memiliki jumlah trial berbeda, FAILED_DELIVERY, INVALID dan
skenario tanpa data. Itu menguji pelaporan nilai kosong; bukan hasil pengukuran RF.
