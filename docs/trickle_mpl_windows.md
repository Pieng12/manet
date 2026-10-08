# Windows: Smoke, Pilot, Utama MPL

Branch MPL. Panduan ini untuk dijalankan manual; implementasi tidak melakukan
commit/push/install/flash/batch perangkat. Tidak menghapus dataset/config lama.
Tutup serial monitor sebelum controller memakai lima port. Laptop tetap hidup;
USB stabil dan HP tetap memperoleh permission Bluetooth scan/advertise.

## Build Pasangan

```powershell
Set-Location D:\PKM\Project\pkmproject
git branch --show-current
git status --short
$env:PLATFORMIO_CORE_DIR='D:\pio'
.\tools\build_neighbor.ps1
if ($LASTEXITCODE -ne 0) { throw 'Build gagal' }
$Artifact=(Get-ChildItem build -Directory -Filter 'neighbor-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$Build=Get-Content (Join-Path $Artifact 'build_manifest.json') -Raw | ConvertFrom-Json
$Fingerprint=.\tools\build_neighbor.ps1 -FingerprintOnly
if ($Fingerprint.source_sha256 -ne $Build.source_sha256) { throw 'Source berubah: build ulang' }
$Artifact
$Build.build_id
```

Script memverifikasi branch/source SHA sebelum dan sesudah build, lalu
mengarsipkan APK, firmware.bin, bootloader, partitions dan factory image.
Gunakan artifact hasil sukses, bukan direktori build sisa yang gagal.

## Install Dan Flash Manual

```powershell
adb devices
py -m serial.tools.list_ports
$Serial='GANTI_SERIAL_ADB'
adb -s $Serial install -r (Join-Path $Artifact 'app-debug.apk')
if ($LASTEXITCODE -ne 0) { throw 'Install gagal' }
adb -s $Serial shell am start -n id.ac.usu.resqmesh/.MainActivity
```

Izinkan Bluetooth/lokasi yang diperlukan melalui HP. Untuk ESP dengan
bootloader/partition layout proyek ini yang sudah benar, flash aplikasi saja
agar NVS tidak dihapus. Ulangi per port dengan node ID disetel controller:

```powershell
$Port='GANTI_COM'
py -m esptool --chip esp32c3 --port $Port write-flash 0x10000 (Join-Path $Artifact 'firmware.bin')
if ($LASTEXITCODE -ne 0) { throw 'Flash gagal' }
```

Untuk board pertama/layout berbeda, periksa kebutuhan bootloader/partitions
terlebih dahulu. Jangan erase-flash atau menimpa NVS tanpa arsip/persetujuan.
Pastikan controller/serial monitor tidak memegang port saat flashing.

## Config Baru Dan Folder Terpisah

Salin contoh ke nama baru, tidak ke config pribadi lama. Edit serial Android,
lima COM sesuai discover, build ID pasangan, session_id dan label. Parameter
MPL sudah lengkap; jangan mengubah 180 s atau delay30/recovery120 tanpa
justifikasi/sesi baru. Graph/tiga metode dikunci oleh validator.

```powershell
py -m pip install -r tools/experiment_controller/requirements.txt
py tools/experiment_controller/run.py discover
$Tag=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$ConfigPath="experiment.mpl.pilot.$Tag.local.json"
Copy-Item tools/experiment_controller/config.mpl.pilot.example.json $ConfigPath
notepad $ConfigPath
```

Isi kedua build ID dengan `$Build.build_id`, serial/COM sesuai perangkat,
session_id `mpl-pilot-<Tag>`. Tetap modes basic_flooding,trickle,trickle_mpl;
semantik resqmesh-trickle-mpl-v1. Config contoh main terpisah dengan15
pengulangan/blok; pilot3, smoke1attempt/kombinasi (diatur command smoke).

## Smoke 9

```powershell
$OutputDir=Join-Path (Get-Location) "experiment_output\mpl-pilot-$Tag"
py tools/experiment_controller/run.py plan --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Plan gagal' }
py tools/experiment_controller/run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal; jangan mulai' }
py tools/experiment_controller/run.py smoke --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Smoke INVALID; periksa raw dan alasan' }
```

Smoke memakai manifest/subfolder smoke tersendiri dalam OutputDir, bukan
bagian dari trial pilot. Smoke PASS berarti prosedur valid, FAILED_DELIVERY
tetap mungkin sah; periksa DSR/recovery, bukan hanya status batch.

Readiness wajib semua build cocok, supported_scheduler_semantics, parameter
efektif, envelope39, graph, radio/epoch/scanner/permission dan tidak ada trial
asing aktif. Jika trial asing aktif, arsipkan/selesaikan secara eksplisit;
jangan reset diam-diam. Perturbasi tercatat Participation dan event
RX_PARTICIPATION_CHANGED/NODE_PARTICIPATION_CHANGED dengan confirmed_enabled,
rx_enabled/scanner_registered/tx_participation. ON bukan sekadar accepted.

## Pilot 27 Lalu Utama135

```powershell
py tools/experiment_controller/run.py run --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Pilot belum selesai; jangan ubah config saat resume' }
py tools/experiment_controller/run.py merge --input (Join-Path $OutputDir 'raw') --output (Join-Path $OutputDir 'merged') --manifest (Join-Path $OutputDir 'manifest.json')
Start-Process (Join-Path $OutputDir 'merged\resqmesh_neighbor_analysis.xlsx')
```

Periksa Log Validation, MPL Diagnostics/Parameters, Receivers recovery,
Method Scenario Summary, raw/charts/setup. `validate-neighbor` opsional memberi
exit2 jika FAIL, exit3 jika INCONCLUSIVE, bukan mengubah hasil delivery:

```powershell
py tools/experiment_controller/run.py validate-neighbor --input (Join-Path $OutputDir 'raw') --output (Join-Path $OutputDir 'validation') --manifest (Join-Path $OutputDir 'manifest.json')
```

Sesudah pilot diterima, buat config dari config.mpl.main.example.json dengan
session_id/folder **mpl-main** baru. Isi artifact ID/port yang sama, bekukan
seed/parameter, ulang plan/readiness/smoke kemudian run. Main15blok x9=135valid,
pilot3blok x9=27valid. Urutan acak tiap blok, seed tercatat. INVALID tetap
di raw/manifest dan pengganti punya attempt ID baru. FAILED_DELIVERY sah tetap
dihitung denominator dan delay gagal kosong. Run lagi config/output sama
untuk resume; jangan ubah fingerprint/sesi di tengah proses.

Durasi window saja: smoke27menit, pilot81menit, main405menit; ditambah setup,
clock/ADB/serial/quiet dan attempt INVALID. Jangan menjanjikan selesai tepat
dalam estimasi itu. Tidak menghapus dataset lama atau memakai folder H1/H2/H3.
