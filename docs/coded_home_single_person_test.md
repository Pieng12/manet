# Uji Coded di Rumah: Satu ESP, Satu Android, Satu Orang

Panduan pilot manual, bukan eksperimen 90 trial. Tidak perlu mengubah firmware,
APK, payload, scheduler, atau algoritma. Gunakan APK dan firmware Coded yang
sudah berhasil pada uji sebelumnya. Hasil hanya berlaku untuk ESP -> Android
pada posisi rumah yang diuji; bukan pembuktian S8 atau jarak maksimum outdoor.

## 1. Persiapan Fisik

1. Di lantai 1, sambungkan HP dan ESP ke laptop melalui USB.
2. Buka ResQMesh di HP. Aktifkan Bluetooth, Lokasi, dan izin aplikasi.
3. Untuk pilot pertama, biarkan aplikasi terbuka dan layar tetap menyala.
   Atur timeout layar yang cukup melalui pengaturan HP.
4. Tutup Serial Monitor Arduino/PlatformIO dan terminal lama yang memakai COM11.
5. Hanya satu ESP pengujian yang menyala. Jangan aktifkan node relay lain.
6. Laptop harus cukup baterai dan tidak sleep selama tes. ESP harus tetap
   terhubung ke laptop ketika dibawa ke lantai 2.
7. Tandai posisi HP dan ESP agar bisa diulang. Catat perkiraan jarak lurus,
   jumlah lantai/dinding, posisi pintu, dan orientasi perangkat. Ini bukan
   panjang jalur berjalan melalui tangga.

Gunakan SATU terminal PowerShell baru untuk seluruh command di bawah. Jangan
menutupnya di tengah tes: variabel dan fungsi harus tetap tersedia. Tidak perlu
menjalankan logcat live di terminal lain, karena ADB akan dicabut sementara.

## 2. Inisialisasi Terminal dan Folder Pilot

Jalankan blok ini sekali. Port terakhir adalah COM11; ubah jika hasil daftar
port berbeda. Folder baru dibuat setiap pengujian, tanpa menghapus output lama.

```powershell
Set-Location D:\PKM\Project\pkmproject
$ErrorActionPreference = 'Stop'
$Serial = 'fbde50b6'
$Port = 'COM11'
$Session = 'coded-home-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$Trial = "$Session-T001"
$OutputDir = Join-Path (Get-Location).Path "experiment_output\$Session"
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$EspLog = Join-Path $OutputDir 'esp_serial.txt'
$PhoneCommandLog = Join-Path $OutputDir 'phone_commands.txt'
$script:EspRxBuffer = ''

adb devices
[System.IO.Ports.SerialPort]::GetPortNames()

Write-Host "Session: $Session"
Write-Host "Output:  $OutputDir"
```

HP harus berstatus `device`, bukan `unauthorized` atau `offline`. Jika tidak,
perbaiki koneksi dan izinkan USB debugging pada HP sebelum melanjutkan.

## 3. Fungsi Command dengan Pemeriksaan Respons Final

Fungsi di panduan ini menggunakan HASHTABLE, bukan bentuk `--es` pada fungsi
lama. Gunakan persis contoh di bawah. Setiap command otomatis mendapat ID unik.
`Send-Phone` menunggu hasil final, bukan sekadar `accepted:true`. Jika gagal
atau timeout, fungsi melempar error: BERHENTI, jangan lanjut blok berikutnya.
Jangan mengirim trigger ulang setelah timeout sebelum memeriksa bukti ESP.

```powershell
function Send-Phone([hashtable]$Data) {
    if (-not $Data.ContainsKey('command_id')) {
        $Data['command_id'] = "$Session-$($Data.command)-$([guid]::NewGuid().ToString('N'))"
    }
    $commandId = [string]$Data.command_id
    $remoteArgs = @('am', 'broadcast', '-a',
        'id.ac.usu.resqmesh.RESEARCH_COMMAND', '-n',
        'id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver')
    foreach ($entry in $Data.GetEnumerator()) {
        $type = '--es'
        if ($entry.Value -is [bool]) { $type = '--ez' }
        elseif ($entry.Value -is [int]) { $type = '--ei' }
        elseif ($entry.Value -is [long]) { $type = '--el' }
        $remoteArgs += @($type, [string]$entry.Key, [string]$entry.Value)
    }
    # Quote for the Android shell, not only the local PowerShell process.
    $shellCommand = (@($remoteArgs | ForEach-Object {
        "'" + ([string]$_).Replace("'", "'\''") + "'"
    }) -join ' ')
    $broadcast = & adb -s $Serial shell $shellCommand
    if ($LASTEXITCODE -ne 0) { throw 'Broadcast ADB gagal. Periksa koneksi HP.' }
    $broadcast | Add-Content -LiteralPath $PhoneCommandLog -Encoding UTF8
    if (($broadcast -join "`n") -match '"accepted"\s*:\s*false') {
        throw 'Broadcast ditolak sebelum pemrosesan command. Periksa parameter dan aplikasi.'
    }
    $wait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($wait.Elapsed.TotalSeconds -lt 30) {
        $lines = & adb -s $Serial logcat -d -s ResQMeshCommand:I
        foreach ($line in $lines) {
            if ($line -notmatch 'RESQMESH_CMD_RESULT (\{.*\})') { continue }
            try { $reply = $Matches[1] | ConvertFrom-Json } catch { continue }
            if ($reply.command_id -ne $commandId) { continue }
            if ($reply.accepted -eq $true) { continue }
            if ($reply.state -eq 'PROCESSING') { continue }
            $line | Add-Content -LiteralPath $PhoneCommandLog -Encoding UTF8
            Write-Host $line
            if ($reply.ok -ne $true) { throw "Command HP gagal: $($reply.error)" }
            return $reply
        }
        Start-Sleep -Milliseconds 400
    }
    throw "Respons final HP timeout: $commandId. Jangan lanjut trial."
}

function Read-EspLines {
    $chunk = $Esp.ReadExisting()
    if ($chunk.Length -eq 0) { return }
    Add-Content -LiteralPath $EspLog -Value $chunk -NoNewline -Encoding UTF8
    $script:EspRxBuffer += $chunk
    while (($index = $script:EspRxBuffer.IndexOf("`n")) -ge 0) {
        $line = $script:EspRxBuffer.Substring(0, $index).TrimEnd("`r")
        $script:EspRxBuffer = $script:EspRxBuffer.Substring($index + 1)
        if ($line.Length -gt 0) { $line }
    }
}

function Send-Esp([hashtable]$Data) {
    if ($null -eq $Esp -or -not $Esp.IsOpen) { throw 'Port ESP belum terbuka.' }
    if (-not $Data.ContainsKey('command_id')) {
        $Data['command_id'] = "$Session-$($Data.command)-$([guid]::NewGuid().ToString('N'))"
    }
    $commandId = [string]$Data.command_id
    $Esp.WriteLine(($Data | ConvertTo-Json -Compress))
    $wait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($wait.Elapsed.TotalSeconds -lt 15) {
        foreach ($line in @(Read-EspLines)) {
            Write-Host $line
            try { $reply = $line | ConvertFrom-Json } catch { continue }
            if ($reply.kind -ne 'response' -or $reply.command_id -ne $commandId) { continue }
            if ($reply.ok -ne $true) { throw "Command ESP gagal: $($reply.error)" }
            return $reply
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Respons ESP timeout: $commandId. Jangan trigger ulang secara buta."
}

function Read-PhoneExport([string]$DevicePath, [string]$LocalName) {
    $raw = & adb -s $Serial exec-out run-as id.ac.usu.resqmesh cat $DevicePath
    if ($LASTEXITCODE -ne 0) { throw "Tidak bisa membaca export: $DevicePath" }
    $json = $raw -join "`n"
    $report = $json | ConvertFrom-Json
    $json | Set-Content -LiteralPath (Join-Path $OutputDir $LocalName) -Encoding UTF8
    return $report
}
```

## 4. Cek HP dan Trial Sebelumnya

```powershell
$PhoneReady = Send-Phone @{command='readiness'}
$PhoneReady | ConvertTo-Json -Depth 8
$PhoneReady | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'phone_before.json') -Encoding UTF8
```

Harus Bluetooth aktif, izin scan/advertise benar, scanner aktif, dan radio ready.
Jika ada masalah scanner, berhenti. Jangan reboot HP di tengah trial.

Jika readiness mempunyai `trial_id`, periksa arsipnya dahulu. Blok ini tidak
otomatis mengubah trial yang sudah selesai atau menebak hasil trial lama.

```powershell
if ($PhoneReady.trial_id) {
    $OldSession = [string]$PhoneReady.session_id
    $OldTrial = [string]$PhoneReady.trial_id
    $OldExport = Send-Phone @{command='export_trial'; session_id=$OldSession; trial_id=$OldTrial}
    $OldReport = Read-PhoneExport $OldExport.json_path 'previous_trial.json'
    $OldReport.trials | Where-Object { $_.trial_id -eq $OldTrial } |
        Format-List trial_id,status,result,failure_reason
    $OldReport.events | Group-Object event_type | Select-Object Name,Count | Format-Table
}
```

Jika status lama `RUNNING` atau `WINDOW_ENDED`, trial harus ditutup sebelum
configure_session. Untuk trial Coded kemarin yang SUDAH memiliki bukti
DESTINATION_FIRST_VALID_RECEIVE, pilih SUCCESS. Jika setup terganggu atau
buktinya tidak jelas, pilih INVALID. Jangan memilih SUCCESS hanya karena TX
berhasil. Jika ini trial penelitian formal, berhenti dan jangan ubah hasilnya
sebagai bagian dari pilot rumah.

HANYA jika trial manual lama masih RUNNING/WINDOW_ENDED, jalankan:

```powershell
$OldResult = Read-Host 'Hasil trial manual lama: SUCCESS, FAILED_DELIVERY, atau INVALID'
if ($OldResult -notin @('SUCCESS','FAILED_DELIVERY','INVALID')) { throw 'Hasil tidak valid.' }
Send-Phone @{command='end_observation_window'; trial_id=$OldTrial} | Out-Null
Send-Phone @{command='finalize_trial'; trial_id=$OldTrial; result=$OldResult} | Out-Null
$OldExport = Send-Phone @{command='export_trial'; session_id=$OldSession; trial_id=$OldTrial}
$OldReport = Read-PhoneExport $OldExport.json_path 'previous_trial_final.json'
```

Jika trial lama sudah COMPLETED/INVALID atau tidak ada trial_id, lewati blok
penutupan di atas. Data output lama tidak dihapus.

## 5. Buka dan Siapkan ESP (Masih di Lantai 1)

```powershell
$Esp = [System.IO.Ports.SerialPort]::new($Port, 115200)
$Esp.DtrEnable = $false
$Esp.RtsEnable = $false
$Esp.NewLine = "`n"
$Esp.Open()

Send-Esp @{command='reset_trial'} | Out-Null
Start-Sleep -Seconds 3
Send-Esp @{command='clock_sync'; wall_time_ms=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()} | Out-Null
Send-Esp @{
    command='configure_session'; node_id='esp-source'; build_id='coded-home-manual'
    session_id=$Session; role='SOURCE'; mode='basic_flooding'; hypothesis='H1'
    node_layer=0; expected_hop_in=0; hop_out=1; rx_burst_gap_ms=1000
    protocol_active=$true; radio_mode='coded'; protocol_version='resqmesh-ble17-v1'
    protocol_epoch_id='resqmesh-2026-06-01'; protocol_epoch_seconds=1780272000
} | Out-Null
$EspReady = Send-Esp @{command='readiness'}
$EspReady | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'esp_before.json') -Encoding UTF8
```

Jika Open gagal Access denied, port masih dimiliki terminal/Serial Monitor lain.
Jangan lanjut. Pesan `packet NOT_FOUND` pada reset state yang memang kosong
bukan bukti radio rusak, selama respons command ok=true dan readiness benar.

ESP harus role SOURCE, radio ready=true, configured_mode=coded,
advertising=false, packet_pending=false, dan clock_valid=true. Catat daya TX
aktualnya, biasanya +9 dBm pada konfigurasi yang sebelumnya diuji.

## 6. Configure Android dan Catat Posisi

Belum start trial atau trigger SOS pada tahap ini.

```powershell
Send-Phone @{
    command='configure_session'; session_id=$Session; session_code='CODED-HOME-H1'
    node_id='android-destination'; role='DESTINATION'; target_hop=1; hypothesis='H1'
    observation_window_ms=300000; mode='basic_flooding'; build_id=$PhoneReady.android_build_id
    node_layer=1; expected_hop_in=1; hop_out=0; rx_burst_gap_ms=1000; radio_mode='coded'
} | Out-Null
$PhoneConfigured = Send-Phone @{command='readiness'}
$PhoneConfigured | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'phone_configured.json') -Encoding UTF8

$PositionNote = Read-Host 'Catatan posisi HP/ESP, jarak perkiraan, lantai/dinding'
$Manifest = [ordered]@{
    session_id=$Session; trial_id=$Trial; test_kind='manual_home_pilot'
    direction='esp_to_android'; mode='basic_flooding'; radio_mode='coded'
    coding_verified=$false; phone_window_ms=300000; source_observation_seconds=60
    android_build_id=$PhoneReady.android_build_id; esp_build_id=$EspReady.firmware_build_id
    position_note=$PositionNote; tx_power_actual_dbm=$EspReady.radio.tx_power_actual_dbm
}
$Manifest | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Encoding UTF8
```

Pastikan readiness Android role DESTINATION, expected_hop_in=1, scanner=true,
session_id sama, gateway_enabled=false dan ack_enabled=false. Jangan lanjut
jika configure_session ditolak karena trial lama masih berjalan.

## 7. Mulai Android, Cabut ADB, Naik ke Lantai 2

Letakkan HP di posisi tetap lantai 1. Jalankan start trial di bawah sebagai
command terakhir sebelum mencabut USB HP. Fungsi menunggu ok=true.

```powershell
Send-Phone @{
    command='start_trial'; session_id=$Session; trial_id=$Trial; trial_code='H1-HOME-T001'
} | Out-Null
$PhoneStarted = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Write-Host 'Android siap. Cabut hanya USB HP; bawa laptop + ESP ke posisi lantai 2.'
```

Android mempunyai window 5 menit sejak start. Pindah ke lantai 2 dalam waktu
sekitar 1 menit. Jangan cabut ESP, pindah port USB, sleep laptop, menutup terminal,
atau trigger ketika masih berjalan naik. Tidak perlu ADB melalui Wi-Fi.

## 8. Kirim SOS Selama 60 Detik di Posisi Lantai 2

Setelah diam di posisi pengujian, jalankan SELURUH blok berikut. Jangan
menjalankan trigger terpisah untuk kedua kalinya.

```powershell
if (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $PhoneStarted) -gt 180000) {
    throw 'Terlalu lama sejak Android start. Jangan trigger. Tutup trial dan ulang dengan sesi baru.'
}
Send-Esp @{command='start_trial'; trial_id=$Trial} | Out-Null
$SourceStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$timer = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Send-Esp @{command='trigger_sos'; latitude=3.5952; longitude=98.6722} | Out-Null
    while ($timer.Elapsed.TotalSeconds -lt 60) {
        foreach ($line in @(Read-EspLines)) { Write-Host $line }
        Start-Sleep -Milliseconds 100
    }
} finally {
    Send-Esp @{command='end_observation_window'} | Out-Null
}
$SourceStopMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Send-Esp @{command='reset_trial'} | Out-Null
Start-Sleep -Seconds 3
$EspStopped = Send-Esp @{command='readiness'}
$EspStopped | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'esp_stopped.json') -Encoding UTF8
if ($EspStopped.advertising -or $EspStopped.packet_pending -or $EspStopped.observation_window_open) {
    throw 'ESP belum benar-benar berhenti. JANGAN turun membawa ESP.'
}
$Manifest['source_start_command_ms'] = $SourceStartMs
$Manifest['source_stop_confirmed_ms'] = $SourceStopMs
$Manifest | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Encoding UTF8
Write-Host 'ESP terkonfirmasi berhenti. Sekarang boleh turun dan sambungkan HP.'
```

Blok menampung log ESP selama pengiriman, termasuk SOS_CREATED dan burst.
Jika error muncul, jangan anggap pengujian berhasil. Jika penghentian gagal,
jangan turun dengan ESP masih menyala: cabut daya ESP DI LANTAI 2 untuk mencegah
TX saat mendekati HP, catat setup gagal/INVALID, baru turun. Jangan reboot ESP
sebelum data diambil: packet persistent bisa kembali setelah reboot.

## 9. Kembali ke Lantai 1, Ambil Bukti Android

Hanya turun setelah langkah 8 menunjukkan ESP berhenti. Sambungkan HP kembali
ke laptop. Jangan trigger lagi atau menghapus logcat.

```powershell
adb devices
adb -s $Serial logcat -d -v threadtime BleWakeUpReceiver:I NativeBleManager:D ResQMeshCommand:I '*:S' |
    Set-Content -LiteralPath (Join-Path $OutputDir 'android_logcat.txt') -Encoding UTF8
Send-Phone @{command='end_observation_window'; trial_id=$Trial} | Out-Null
$Export = Send-Phone @{command='export_trial'; session_id=$Session; trial_id=$Trial}
$Report = Read-PhoneExport $Export.json_path 'android_trial_before_finalize.json'
$Report.events | Group-Object event_type | Select-Object Name,Count | Format-Table

$EspEvents = @(Get-Content -LiteralPath $EspLog | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch {}
})
$Sos = $EspEvents | Where-Object {
    $_.event_type -eq 'SOS_CREATED' -and $_.trial_id -eq $Trial
} | Select-Object -Last 1
if ($null -eq $Sos) { throw 'SOS_CREATED tidak ditemukan. Jangan klaim sukses.' }
$Receive = @($Report.events | Where-Object {
    $_.event_type -eq 'DESTINATION_FIRST_VALID_RECEIVE' -and
    $_.sender_crc -eq $Sos.sender_crc -and
    $_.protocol_timestamp_ms -eq $Sos.protocol_timestamp_ms -and $_.hop_in -eq 1
})
$Receive | Format-List event_type,event_timestamp_ms,sender_crc,protocol_timestamp_ms,hop_in,rssi
Select-String -LiteralPath (Join-Path $OutputDir 'android_logcat.txt') -Pattern 'RX PHY'
Write-Host "Penerimaan tujuan yang cocok: $($Receive.Count)"
Write-Host "Semua bukti berada di: $OutputDir"
```

Keberhasilan membutuhkan receive yang cocok dengan SOS_CREATED, bukan hanya
source advertising. Cocokkan juga sender_crc, timestamp_compact, hop=1 dan
primary=3 secondary=3 legacy=false pada log Android. timestamp_compact adalah
protocol_timestamp_ms / 1000 - 1780272000. Jangan memakai log sesi lama.

Window Android 5 menit adalah waktu untuk penyiapan/pindah; ESP hanya mengirim
sekitar 60 detik pada posisi lantai 2. Karena ESP belum trigger saat berdekatan
dan sudah berhenti sebelum turun, penerimaan bukan hasil mendekat kembali.
Clock ESP disetel dari laptop, bukan kalibrasi offset Android untuk penelitian;
jangan memakai selisih jam lintas perangkat sebagai latency resmi dari pilot ini.

Tidak ada receive dengan setup sehat -> FAILED_DELIVERY. Setup/radio/scanner
gagal, waktu window terlewati, ESP reboot/pindah, atau bukti tidak lengkap ->
INVALID. Ada receive yang cocok dan PHY Coded terkonfirmasi -> SUCCESS untuk
pilot Coded rumah. Jika receive ada tetapi log PHY tidak tersedia, catat
penerimaan sukses namun PHY pada trial ini belum terverifikasi; jangan mengklaim
S8 atau memalsukan bukti PHY.

## 10. Finalisasi, Simpan Arsip Final, dan Lepaskan Port

Pilih hasil sesuai bukti langkah 9. Prompt sengaja tidak menebak hasil tes.

```powershell
$Result = Read-Host 'Hasil: SUCCESS, FAILED_DELIVERY, atau INVALID'
if ($Result -notin @('SUCCESS','FAILED_DELIVERY','INVALID')) { throw 'Hasil tidak valid.' }
$Reason = Read-Host 'Catatan hasil (mis. received_coded_across_floor atau no_receive_60s)'
Send-Phone @{command='finalize_trial'; trial_id=$Trial; result=$Result; reason=$Reason} | Out-Null
$FinalExport = Send-Phone @{command='export_trial'; session_id=$Session; trial_id=$Trial}
$FinalReport = Read-PhoneExport $FinalExport.json_path 'android_trial.json'
$csv = & adb -s $Serial exec-out run-as id.ac.usu.resqmesh cat $FinalExport.csv_path
if ($LASTEXITCODE -ne 0) { throw 'Tidak bisa mengambil CSV. Jangan reset dulu.' }
$csv | Set-Content -LiteralPath (Join-Path $OutputDir 'android_trial.csv') -Encoding UTF8
$Manifest['result'] = $Result
$Manifest['reason'] = $Reason
$Manifest | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Encoding UTF8
Send-Phone @{command='reset_trial'; trial_id=$Trial} | Out-Null
$Esp.Close()
$Esp.Dispose()
Start-Process explorer.exe -ArgumentList $OutputDir
```

Reset Android dilakukan hanya SETELAH arsip final berhasil diambil. Command
tersebut menghapus state protocol pilot yang aktif, bukan archived research
events atau dataset output lama. Jangan menerapkannya ke trial formal lain.

Output pilot ini berupa JSON, CSV, dan log mentah; tidak otomatis menjadi workbook
90-trial dan tidak dicampur ke dataset formal. Kirim android_trial.json,
esp_serial.txt, android_logcat.txt, dan manifest.json untuk pemeriksaan.

Untuk mengulang posisi sama/posisi lain, jalankan ulang dari langkah 2 setelah
semua port/trial sebelumnya ditutup. Session, command ID, dan output akan baru.
Tes pertama membuktikan satu pengiriman, bukan tingkat keandalan atau jarak
maksimum; ulang beberapa kali sebelum menyimpulkan konsistensi.

## Perbaikan Helper untuk Catatan dengan Spasi

Versi awal helper meneruskan nilai reason seperti `rssi = -101, hop in 1`
sebagai argumen lokal ADB tanpa quoting pada shell Android. Akibatnya receiver
dapat menerima command kosong dan accepted=false, sementara helper menunggu
command_id yang tidak pernah diterima. Itu bukan kegagalan transmisi SOS.

Helper langkah 3 sudah diperbaiki: seluruh argumen remote di-quote, termasuk
spasi, tanda petik, dan karakter shell. Broadcast accepted=false juga langsung
dilaporkan sebagai error, bukan menunggu timeout. Jika terminal masih memakai
fungsi lama, jalankan ulang HANYA blok fungsi pada langkah 3; jangan membuat
sesi baru atau mengirim SOS lagi untuk menyelesaikan arsip trial yang sama.

Untuk timeout finalisasi, cek export/status trial dahulu. Jika masih
WINDOW_ENDED, finalisasi trial yang sama berdasarkan bukti yang tersimpan,
export dan ambil file final, baru reset. Jangan mengulang tes fisik hanya karena
command administratif gagal. Logcat dapat terputar sebelum kabel disambungkan
kembali: apabila RX PHY tidak ada di log tersimpan, tandai bukti PHY spesifik
trial tersebut belum tersedia; keberhasilan SOS tetap dapat dibuktikan oleh
event durable yang cocok.
