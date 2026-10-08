# Smoke Full Profil Tetangga Di Windows

Panduan untuk terminal PowerShell baru di `D:\PKM\Project\pkmproject`.
Smoke ini memakai satu Android sebagai SOURCE dan lima ESP32-C3 sebagai
penerima/relay. Jalankan seluruh blok berurutan di terminal yang sama.
Tidak ada perintah run eksperimen utama dalam panduan ini.

## 1. Siapkan Perangkat

1. Sambungkan HP dan kelima ESP ke laptop dengan kabel data yang stabil.
2. Aktifkan USB debugging HP dan terima izin komputer. Aktifkan Bluetooth.
3. Tutup Serial Monitor PlatformIO/Arduino, terminal Send-Esp, dan controller
   lain. Satu COM hanya boleh dibuka satu proses pada saat pengujian.
4. Letakkan perangkat pada posisi tetap dan tandai masing-masing ESP A/B/C/D/E.
   Jangan mengubah posisi selama smoke. Graph berikut bersifat logis, bukan
   bukti bahwa RF hanya melewati link yang digambar.
5. Sambungkan charger laptop; nonaktifkan sleep/hibernate sementara dan jangan
   tutup laptop jika akan membuatnya sleep. Pastikan daya USB cukup untuk lima ESP.
6. Periksa Research Monitor: jika masih ada trial lama aktif, jangan mulai sesi
   baru. Selesaikan/invalidate dan arsipkan secara eksplisit dahulu. Jangan
   uninstall, clear data aplikasi, erase_flash, atau menghapus dataset lama.

| Perangkat | Identitas controller | Sambungan |
| --- | --- | --- |
| S | android-source | Serial ADB HP |
| A | esp-r1a | COM A |
| B | esp-r1b | COM B |
| C | esp-r2a | COM C |
| D | esp-r2b | COM D |
| E | esp-destination | COM E |

Semua lima ESP berperan RELAY sekaligus target penerimaan, termasuk E.
Graph: S-A, S-B, A-C, B-C, A-D, D-E.

## 2. Periksa Terminal Dan Toolchain

```powershell
Set-Location D:\PKM\Project\pkmproject
if ((git branch --show-current).Trim() -ne 'metode-penerimaan') {
    throw 'Branch harus metode-penerimaan; jangan lanjut'
}
git status --short

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Program @Arguments
        $Code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
    if ($Code -ne 0) { throw "$Program gagal (exit $Code); jangan lanjut" }
}

Invoke-Checked 'flutter' @('--version')
Invoke-Checked 'py' @('--version')
Invoke-Checked 'py' @('-m', 'pip', 'install', '-r', 'tools/experiment_controller/requirements.txt')
Invoke-Checked 'py' @('-m', 'platformio', '--version')
Invoke-Checked 'adb' @('devices', '-l')
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'discover')
if (Test-Path -LiteralPath 'D:\pio') { $env:PLATFORMIO_CORE_DIR = 'D:\pio' }
```

Jika PlatformIO belum terpasang, jalankan `py -m pip install platformio`, periksa
exit code, lalu ulang pengecekan PlatformIO. HP harus berstatus `device`, bukan
`unauthorized`/`offline`. Catat COM aktual kelima ESP dari discover; jangan
menganggap COM lama tetap sama setelah kabel dipindahkan.

Isi jawaban saat diminta berikut, misalnya serial HP `fbde50b6` jika masih itu.
Untuk COM, masukkan `COM11`, bukan angka `11`. Jangan isi contoh tanpa memeriksa.

```powershell
$Serial = (Read-Host 'Serial ADB HP dari adb devices').Trim()
$Ports = [ordered]@{
    A = (Read-Host 'COM ESP A / esp-r1a').Trim().ToUpperInvariant()
    B = (Read-Host 'COM ESP B / esp-r1b').Trim().ToUpperInvariant()
    C = (Read-Host 'COM ESP C / esp-r2a').Trim().ToUpperInvariant()
    D = (Read-Host 'COM ESP D / esp-r2b').Trim().ToUpperInvariant()
    E = (Read-Host 'COM ESP E / esp-destination').Trim().ToUpperInvariant()
}
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Serial HP kosong' }
if (@($Ports.Values | Where-Object { $_ -notmatch '^COM[0-9]+$' }).Count -gt 0) {
    throw 'Isi kelima COM dengan benar'
}
if (@($Ports.Values | Sort-Object -Unique).Count -ne 5) {
    throw 'Kelima COM harus berbeda'
}
Invoke-Checked 'adb' @('-s', $Serial, 'get-state')
$Ports
```

## 3. Siapkan Pasangan Build

Jika APK/firmware profil tetangga yang sama sudah terpasang dan build ID-nya
diketahui, bagian build/install/upload boleh dilewati: isi `$BuildId` dengan
ID 12 karakter dari manifest pasangan yang benar-benar terpasang. Readiness
nanti wajib memverifikasi ID keenam perangkat. Koreksi validator Python saja
tidak memerlukan flash/install baru. Jangan memakai fingerprint source terbaru
sebagai ID perangkat yang belum dibuild/diinstall.

Jika belum yakin binary yang terpasang, jalankan build pasangan baru berikut.
Tidak mengubah algoritma; script membekukan hash source dan menyamakan ID.

```powershell
$Fingerprint = & .\tools\build_neighbor.ps1 -FingerprintOnly
$BuildId = $Fingerprint.build_id
& .\tools\build_neighbor.ps1
$Artifact = Get-ChildItem -LiteralPath build -Directory -Filter "neighbor-$BuildId-*" |
    Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $Artifact) { throw 'Folder pasangan build tidak ditemukan' }
$BuildManifest = Get-Content -LiteralPath (Join-Path $Artifact.FullName 'build_manifest.json') -Raw | ConvertFrom-Json
if ($BuildManifest.build_id -ne $BuildId -or $BuildManifest.source_sha256 -ne $Fingerprint.source_sha256) {
    throw 'Manifest pasangan tidak cocok; jangan install/flash'
}
$Apk = Join-Path $Artifact.FullName 'app-debug.apk'
Invoke-Checked 'adb' @('-s', $Serial, 'install', '-r', $Apk)
Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'am', 'start', '-n', 'id.ac.usu.resqmesh/.MainActivity')

$OldBuildId = $env:RESQMESH_BUILD_ID
try {
    $env:RESQMESH_BUILD_ID = $BuildId
    foreach ($Port in $Ports.Values) {
        Write-Host "Upload ESP pada $Port"
        Invoke-Checked 'py' @('-m', 'platformio', 'run', '-d', 'firmware/esp32c3', '-e', 'esp32c3', '-t', 'upload', '--upload-port', $Port)
    }
} finally {
    $env:RESQMESH_BUILD_ID = $OldBuildId
}
```

Setelah install: buka aplikasi, berikan izin Bluetooth scan/advertise, aktifkan
relay/service yang diperlukan dan gunakan mode offline. Jangan memulai trial
manual/SOS dari UI. Controller akan mengonfigurasi sesi dan memicu satu SOS
per trial. Jangan mengedit source atau memasang build berbeda di tengah smoke.

## 4. Buat Config Dan Folder Baru

Blok ini menggunakan template full, bukan config smoke lama untuk profil hop.
Folder baru terpisah dari smoke/90/135 trial dan Uji Jarak sebelumnya.

```powershell
if ($BuildId -notmatch '^[0-9a-fA-F]{12}$') { throw 'Build ID pasangan belum benar' }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$ConfigPath = Join-Path (Get-Location) "experiment.neighbor.smoke.$Stamp.local.json"
$OutputDir = Join-Path (Get-Location) "experiment_output\neighbor-smoke-$Stamp"
if ((Test-Path -LiteralPath $ConfigPath) -or (Test-Path -LiteralPath $OutputDir)) {
    throw 'Nama output sudah ada; gunakan sesi baru, jangan timpa'
}
$Config = Get-Content -LiteralPath 'tools/experiment_controller/config.neighbor.full.example.json' -Raw | ConvertFrom-Json
$Config.session_id = "neighbor-smoke-$Stamp"
$Config.session_label = 'neighbor-full-smoke'
$Config.android_build_id = $BuildId
$Config.firmware_build_id = $BuildId
$Config.valid_trials_per_condition = 1
$Config.max_attempts_per_condition = 1
$Config.nodes[0].serial = $Serial
$Config.nodes[1].port = $Ports.A
$Config.nodes[2].port = $Ports.B
$Config.nodes[3].port = $Ports.C
$Config.nodes[4].port = $Ports.D
$Config.nodes[5].port = $Ports.E
$Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Config: $ConfigPath"
Write-Host "Output: $OutputDir"
```

Isi yang dipertahankan: empat metode, tiga skenario, window 180 detik,
perturbasi 30 detik, minimum recovery 120 detik, quiet period 5 detik,
radio coded, gateway/completion ACK disabled. TX requested ESP +20 dBm dan
Android +1 dBm; periksa TX aktual dari log, jangan menganggap requested selalu
sama dengan actual. Coded PHY bukan bukti coding S=8.

## 5. Plan, Readiness, Lalu Smoke

Jalankan satu blok pada satu waktu. Jika muncul error, jangan lanjut blok berikut.

```powershell
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'plan', '--config', $ConfigPath, '--output', $OutputDir)
```

Plan harus menampilkan `planned_trials = 12` dan `target_valid_trials = 12`.
Smoke sendiri memakai satu attempt per kombinasi dan urutan diacak seimbang.

```powershell
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'readiness', '--config', $ConfigPath, '--output', $OutputDir)
```

Readiness harus berhasil untuk keenam perangkat: ID build cocok, coded didukung,
inner payload 17 byte, epoch/clock valid, Bluetooth/izin dan scanner sesuai.
Jika ada trial lama/asing aktif, hentikan persiapan dan arsipkan dahulu;
controller tidak boleh mengganti trial yang belum diarsipkan begitu saja.

```powershell
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'smoke', '--config', $ConfigPath, '--output', $OutputDir)
```

Biarkan hingga proses kembali ke prompt. Minimum pengamatan 36 menit;
alokasikan sekitar 45-60 menit, bukan jaminan batas waktu. Jangan cabut USB,
membuka serial kedua, mengirim command manual, memicu SOS, atau membiarkan
laptop sleep. S1 scanner D OFF/ON dan S2 TX/RX E OFF/ON otomatis, tidak perlu
mematikan atau mencabut ESP. Jika ada error, simpan raw/manifest dan periksa;
jangan terus menekan Ctrl+C atau menghapus bukti untuk mencoba lagi.

## 6. Lihat Jumlah Selesai Dan Buka Excel

Pada saat smoke berjalan, jika ingin memeriksa progres, pakai terminal KEDUA
hanya untuk membaca file, bukan membuka ADB/COM lain. Isi ulang path output
dari tulisan pada bagian 4; variabel terminal pertama tidak otomatis tersedia.

```powershell
# Di terminal kedua saja: isi path aktual yang dicetak sebelumnya.
$OutputDir = Read-Host 'Path lengkap output smoke'
$ManifestFile = Join-Path $OutputDir 'smoke_run\manifest.json'
if (Test-Path -LiteralPath $ManifestFile) {
    $Manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
    $Trials = @($Manifest.trials.PSObject.Properties.Value)
    $Trials | Group-Object result | Select-Object Name, Count
    $Finished = @($Trials | Where-Object { $_.result -in @('SUCCESS', 'FAILED_DELIVERY', 'INVALID') }).Count
    Write-Host "Attempt selesai: $Finished / 12 (termasuk INVALID jika ada)"
}
```

Jika file sedang ditulis dan JSON gagal dibaca, tunggu sebentar lalu ulang
pembacaan; jangan mengubah file manifest. Jumlah attempt selesai bukan
jumlah trial valid atau delivery sukses.

Setelah smoke selesai, kembali ke terminal PERTAMA:

```powershell
$Report = Get-Content -LiteralPath (Join-Path $OutputDir 'smoke_report.json') -Raw | ConvertFrom-Json
$Report | ConvertTo-Json -Depth 8
$Workbook = Join-Path $OutputDir 'smoke_merged\resqmesh_neighbor_analysis.xlsx'
if (-not (Test-Path -LiteralPath $Workbook)) { throw 'Excel belum tersedia; periksa log proses' }
Invoke-Item -LiteralPath $Workbook
```

- Excel: `$OutputDir\smoke_merged\resqmesh_neighbor_analysis.xlsx`.
- Raw dan manifest smoke: `$OutputDir\smoke_run\raw\` dan
  `$OutputDir\smoke_run\manifest.json`.
- Ringkasan: `$OutputDir\smoke_report.json` dan `smoke_report.csv`.

`passed = true` pada smoke menunjukkan kriteria smoke controller terpenuhi,
bukan berarti semua kasus diagnostik teramati atau setiap trial sukses delivery.
FAILED_DELIVERY yang memenuhi prosedur/log adalah data sah, bukan alasan untuk
mengulang sampai sukses. INVALID berarti bukti/prosedur bermasalah dan wajib
diperiksa. Periksa Trial Metrics, Receivers, Participation, Invalid Trials,
Mechanism Diagnostics, PHY Evidence, Log Validation, dan All Events.

## 7. Validator Offline

Tidak membutuhkan perangkat dan tidak mengubah raw/hasil trial. Pakai folder baru.

```powershell
$CheckDir = Join-Path $OutputDir ("validation-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
py tools\experiment_controller\run.py validate-neighbor --input (Join-Path $OutputDir 'smoke_run\raw') --manifest (Join-Path $OutputDir 'smoke_run\manifest.json') --output $CheckDir
$ValidationExit = $LASTEXITCODE
Write-Host "Validator exit: $ValidationExit (0 PASS; 2 ada FAIL; 3 INCONCLUSIVE)"
Invoke-Item -LiteralPath $CheckDir
```

Jangan memakai Invoke-Checked untuk validator karena INCONCLUSIVE dapat
merupakan hasil yang diharapkan bagi kasus yang tidak terjadi, seperti kegagalan
advertising. INCONCLUSIVE bukan PASS dan bukan otomatis kegagalan delivery.
LOG_COMPLETENESS/rumus, actual OFF/ON, serta setiap FAIL tetap perlu diperiksa.
Kasus pilot khusus dijelaskan dalam [panduan validator](neighbor_status_windows.md#6-validator-log-dan-kasus-pilot).

Panduan ini berhenti pada smoke dan pemeriksaan arsip. Jangan langsung
menjalankan batch utama sebelum bukti pilot ditinjau dan konfigurasi dibekukan.

## 8. Pemulihan Invalid Stable Transmitter Adjacency

Pada smoke `neighbor-smoke-20261008-023027-389`, semua 12 attempt gagal pada
configure_session Android sebelum pengamatan dimulai. Manifest mencatat
`Invalid argument(s): Invalid stable transmitter adjacency`. Ini bukan hasil
FAILED_DELIVERY atau masalah durasi window/TX power.

Receiver debug Android sebelumnya memasukkan String[] dari ADB --esa langsung
ke JSONObject.put. Sekarang extras dibungkus dengan JSONObject.wrap, sehingga
allowed_transmitters sampai ke Dart sebagai JSON array. Konversi standar ini
mempertahankan integer/long/boolean/string dan nilai ID unsigned di atas 2^31.
Rujukan: [JSONObject.wrap Android](https://developer.android.com/reference/org/json/JSONObject#wrap(java.lang.Object)).
Validasi adjacency, graph, scheduler, radio/power, payload dan transaksi tidak
dilonggarkan. Firmware source tidak berubah oleh perbaikan ini.

Jangan ulang command smoke pada folder gagal yang sama: command ID/result
idempoten dapat mengembalikan kegagalan lama dan max attempt sudah habis.
Pertahankan folder tersebut sebagai bukti INVALID.

1. Jalankan ulang bagian 3 untuk membuat pasangan build yang memuat fix.
2. Install APK baru dengan -r. Untuk workflow pasangan baru, upload kelima ESP
   juga: build ID keenam perangkat harus sama, walaupun perubahan fungsional
   hanya pada receiver Android.
3. Jalankan bagian 4 untuk config/session/output baru; isi ID pasangan baru.
4. Jalankan plan, readiness, smoke pada bagian 5. Jangan jalankan run dahulu.

Jika ingin mempertahankan COM/serial yang sudah benar dari config gagal,
gunakan blok berikut sebagai pengganti bagian 4 setelah build/install/upload.
Invoke-Checked dan BuildId harus sudah tersedia dari bagian 2-3.

```powershell
$OldConfig = 'experiment.neighbor.smoke.20261008-023027-389.local.json'
$Config = Get-Content -LiteralPath $OldConfig -Raw | ConvertFrom-Json
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$ConfigPath = Join-Path (Get-Location) "experiment.neighbor.smoke.$Stamp.local.json"
$OutputDir = Join-Path (Get-Location) "experiment_output\neighbor-smoke-$Stamp"
if ((Test-Path -LiteralPath $ConfigPath) -or (Test-Path -LiteralPath $OutputDir)) {
    throw 'Sesi/output sudah ada; jangan timpa'
}
$Config.session_id = "neighbor-smoke-$Stamp"
$Config.android_build_id = $BuildId
$Config.firmware_build_id = $BuildId
$Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'plan', '--config', $ConfigPath, '--output', $OutputDir)
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'readiness', '--config', $ConfigPath, '--output', $OutputDir)
Invoke-Checked 'py' @('tools/experiment_controller/run.py', 'smoke', '--config', $ConfigPath, '--output', $OutputDir)
```

Pemulihan di perangkat tetap harus dibuktikan dengan smoke fisik baru. Tes unit
konversi array dan konfigurasi keempat metode bukan pengganti penerimaan hardware.

Pemeriksaan fix pada 2026-10-08: format lulus (97 file, 0 perubahan), analyze
bersih, 400 tes Flutter, 50 tes native Gradle, dan 133 tes Python lulus. Sebelum
fix, dua tes native array gagal; sesudah wrapping keduanya lulus. Algoritma,
power, firmware source, dan arsip smoke gagal tidak diubah. Tidak ada commit,
push, install, atau flash oleh perbaikan ini.

Pasangan siap untuk install/flash manual:
`build/neighbor-63b1f10f01a9-20261008-025411-000/`, build ID `63b1f10f01a9`.
Berisi app-debug.apk, firmware.bin, dan build_manifest.json; fingerprint source
diperiksa cocok setelah build. Ini bukan bukti smoke hardware sudah lulus.
Jika memakai pasangan ini, tidak perlu mengulang build: gunakan ID/folder ini
untuk instalasi dan bagian pemulihan di atas. Pastikan source/config tetap sesuai.
