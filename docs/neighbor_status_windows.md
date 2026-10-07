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
