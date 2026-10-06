# Uji Jarak Coded Satu Orang

Pilot ini mengukur penerimaan **ESP -> Android**. Laptop dan ESP tetap di posisi
sumber; HP dibawa berjalan ke beberapa titik berhenti yang aman. Bukan eksperimen
135 trial, bukan pengukuran jarak maksimum universal, dan bukan bukti S8.

Panduan daya tinggi ini memakai firmware yang meminta **+20 dBm** pada ESP32-C3
dan APK yang meminta **+1 dBm / TX_POWER_HIGH** pada Android. Daya aktual tetap
ditentukan controller. Pada pilot ini HP hanya menerima: menaikkan TX power HP
tidak menambah kemampuan RX HP dan tidak membuktikan jangkauan HP -> ESP.
Untuk menerapkan perubahan daya, **install APK baru dan flash firmware baru**.
Payload 17 byte, algoritma, interval dan durasi burst tidak berubah.

## 1. Siapkan Perangkat dan Terminal

Selesaikan dan arsipkan pengujian lama terlebih dahulu. Jangan mengganti firmware
atau APK di tengah trial. Jangan hapus dataset, clear data aplikasi, atau format
ESP. Tutup Excel hasil lama sebelum ekspor ulang ke file yang sama.

Sambungkan HP dan satu ESP32-C3 ke laptop. Tutup Serial Monitor, PlatformIO Monitor,
Arduino Serial Monitor, controller eksperimen, dan PowerShell lama yang memegang
COM. Jika objek serial masih ada di terminal lama, jalankan di terminal itu:

```powershell
if ($null -ne $Esp) {
    if ($Esp.IsOpen) { $Esp.Close() }
    $Esp.Dispose()
    $Esp = $null
}
```

Jika ESP masih advertising dari sesi yang tidak selesai, arsipkan/finalisasi sesi
itu dengan prosedur lamanya sebelum mencoba panduan ini. Jangan menganggap hasil
lama SUCCESS hanya untuk melewati pemeriksaan.

Buka PowerShell baru. Semua blok di bawah dijalankan dari root repository:

```powershell
Set-Location 'D:\PKM\Project\pkmproject'
$ErrorActionPreference = 'Stop'
$Serial = 'fbde50b6'
$Port = 'COM11'
$env:PLATFORMIO_CORE_DIR = 'D:\pio'
$BuildId = (git rev-parse --short=12 HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Tidak bisa membaca revisi repository' }
$env:RESQMESH_BUILD_ID = $BuildId
git branch --show-current
adb devices -l
[System.IO.Ports.SerialPort]::GetPortNames()
py --version
py -m platformio --version
flutter --version
```

Ganti `$Serial` dan `$Port` jika hasil pemeriksaan berbeda. ADB harus menunjukkan
`device`, bukan `unauthorized` atau `offline`. Jika unauthorized, buka kunci HP
dan izinkan USB debugging. COM11 hanyalah contoh perangkat sebelumnya.

Build ID berbasis HEAD pada working tree yang belum di-commit belum membedakan
semua perubahan lokal. Ini boleh untuk pilot lokal; sebelum eksperimen formal,
bekukan revisi dan build ulang dari revisi tersebut. Panduan tidak melakukan
commit atau push.

Pasang kebutuhan Python bila belum tersedia:

```powershell
py -m pip install -r tools\experiment_controller\requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Instalasi kebutuhan Python gagal' }
```

Jika modul PlatformIO belum ada, jalankan `py -m pip install platformio`, lalu
ulangi pemeriksaan versi. Jangan menjalankan beberapa build/flash bersamaan.

## 2. Build dan Install APK Baru

```powershell
flutter build apk --debug --dart-define=RESQMESH_MODE=offline --dart-define=RESQMESH_BUILD_ID=$BuildId
if ($LASTEXITCODE -ne 0) { throw 'Build APK gagal; jangan install APK lama' }
adb -s $Serial install -r build\app\outputs\flutter-apk\app-debug.apk
if ($LASTEXITCODE -ne 0) { throw 'Install APK gagal' }
adb -s $Serial shell am start -n id.ac.usu.resqmesh/.MainActivity
if ($LASTEXITCODE -ne 0) { throw 'Aplikasi tidak bisa dibuka' }
```

`install -r` mempertahankan data aplikasi. Jangan uninstall atau menjalankan
`pm clear`. Di HP, aktifkan Bluetooth dan lokasi, izinkan Nearby devices dan
lokasi presisi saat aplikasi digunakan. Buka **Research Monitor -> UJI JARAK**.
Pertahankan layar menyala dan aplikasi di depan; jangan pindah tab selama titik
pengamatan. Jika perlu, atur timeout layar lewat pengaturan HP dan catat nilai
lama untuk dikembalikan setelah uji. Pilot ini tidak melacak lokasi background.

## 3. Build dan Flash ESP32-C3

Pastikan ESP yang dipilih benar-benar ESP32-C3 dan COM-nya sesuai. HP tetap boleh
terhubung; tidak ada program lain yang boleh memegang COM ESP.

```powershell
py -m platformio run -d firmware/esp32c3 -e esp32c3
if ($LASTEXITCODE -ne 0) { throw 'Build firmware gagal; jangan lanjut upload' }
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port $Port
if ($LASTEXITCODE -ne 0) { throw 'Upload ESP gagal; jangan mulai pilot' }
Start-Sleep -Seconds 5
```

Jika upload meminta bootloader, ikuti tombol BOOT/RESET board saat connecting.
Jika COM berubah setelah reset, periksa `GetPortNames()` lagi dan ubah `$Port`.
**Jangan membuka serial monitor setelah flash** karena script uji harus menjadi
pemilik port. Tidak perlu mengganti firmware lagi untuk setiap titik pengamatan.

## 4. Mulai Pilot Baru

Sambungkan laptop ke listrik, cegah sleep selama minimal 25 menit, dan tinggalkan
ESP tetap tersambung di posisi sumber. Jangan menutup lid jika membuat laptop
sleep. Folder baru berikut tidak bercampur dengan smoke atau pengujian utama:

```powershell
$OutputDir = Join-Path (Get-Location).Path ('experiment_output\coded-range-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$OutputDir
powershell -NoProfile -ExecutionPolicy Bypass -File tools\range_test.ps1 -Phase Run -Serial $Serial -Port $Port -OutputDir $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Pilot gagal; jangan mulai SOS lain sebelum membaca error dan mengarsipkan hasil' }
```

Jangan membuat folder `$OutputDir` terlebih dahulu: script menolak folder yang
sudah ada agar tidak menimpa data. Catat path yang dicetak; proses Run akan
menahan terminal sekitar 20 menit. Jangan menjalankan Collect di terminal itu
sebelum Run selesai. Tidak perlu mendefinisikan `Send-Phone` atau `Send-Esp`.

Script memeriksa build, scanner, Coded readiness, clock, epoch, trial lama dan
port. Script menolak trial Android belum difinalisasi, pilot lama masih aktif,
atau ESP yang masih memiliki packet/window aktif; tidak mengubah hasil lama.

Ketika muncul permintaan menandai posisi ESP, dalam 120 detik lakukan di HP:

1. HP masih berada dekat ESP dan USB masih tersambung.
2. Pilih ikon **Posisi ESP dari GPS HP** jika akurasi <=20 m dan lokasi segar.
3. Jika GPS dalam kamar tidak layak, gunakan **Posisi ESP manual** atau pin peta
   dengan koordinat sumber yang benar. Jangan memasukkan koordinat contoh.
4. Biarkan tab UJI JARAK terbuka. Tunggu **BASELINE PASSED** di laptop.

Baseline mengharuskan RX dengan identitas SOS yang cocok dan PHY aktual Coded,
bukan hanya konfigurasi requested Coded. Hanya satu SOS dipicu. Jangan menekan
tombol SOS atau mengirim `trigger_sos` lagi.

### Periksa Daya Baru Tanpa Mengganggu Run

Opsional tetapi disarankan: buka PowerShell kedua setelah file `esp_before.json`
tersimpan, lalu masukkan path folder yang dicetak Run:

```powershell
$OutputDir = 'D:\PKM\Project\pkmproject\experiment_output\coded-range-YYYYMMDD-HHMMSS'
$EspReady = Get-Content -LiteralPath (Join-Path $OutputDir 'esp_before.json') -Raw | ConvertFrom-Json
$PhoneReady = Get-Content -LiteralPath (Join-Path $OutputDir 'phone_before.json') -Raw | ConvertFrom-Json
$EspReady.radio | Format-List
$PhoneReady.radio | Format-List
```

ESP harus meminta `tx_power_requested_dbm=20`; periksa nilai aktual yang dilaporkan,
`ready=true`, `configured_mode=coded`, dan `last_error=0`. Jika permintaan masih 9,
firmware baru belum digunakan. Android harus meminta 1, bukan -7; nilai aktual
Android boleh null karena HP adalah DESTINATION, tidak sedang advertising.
Jika actual ESP lebih rendah dari 20, catat nilai itu, bukan klaim +20 dBm.
Jika baseline tidak lolos atau build salah, jangan membawa HP pergi. Jangan
mematikan source melalui terminal kedua saat Run masih berlangsung.

## 5. Bawa HP dan Amati Titik

**Hanya setelah `BASELINE PASSED`, cabut USB HP saja.** Laptop, ESP, dan terminal
Run tetap menyala di kamar. HP tidak membutuhkan ADB saat dibawa menjauh.

1. Buat satu titik dekat sebagai pembanding selama sesi, bukan hanya baseline.
2. Berjalan ke titik aman. Saat sudah diam, tekan **Mulai Pengamatan**. Dialog
   menyediakan horizontal manual dalam meter, beda tinggi HP - ESP,
   metode (Meteran, Denah berskala, Perkiraan manual) dan catatan. Semuanya
   opsional; kosong berarti tidak diketahui, bukan nol. Masukkan `0` jika
   memang diukur nol; beda tinggi boleh negatif jika HP di bawah ESP.
3. Tekan **Mulai 60 Detik**, lalu tunggu **Pengamatan Selesai** sebelum pindah.
   Input manual hanya untuk titik itu dan tidak disalin otomatis ke titik baru.
4. Amati paket terakhir, usia RX, RSSI, PHY aktual, lokasi dan sisa sesi.
5. Uji beberapa titik menjauh dan satu titik kembali mendekat jika waktu cukup.
   Sisakan waktu perjalanan; satu sesi hanya 20 menit sejak baseline selesai.

Jangan mengunci layar, memindahkan app ke background, atau menutup tab UJI JARAK
saat titik berjalan; titik akan dibatalkan dengan alasan. Jangan berjalan sambil
membaca layar atau berkendara sambil mengoperasikan HP. Tombol pengamatan tidak
membuat SOS/trial penelitian baru.

GPS dengan usia >5 detik atau akurasi >20 m tidak layak untuk ringkasan jarak.
GPS hilang atau peta offline tidak menghapus RX; jarak dapat kosong. Pin/manual
tidak memiliki akurasi GPS terukur. Jarak merupakan garis lurus horizontal,
bukan rute berjalan, jumlah dinding atau beda lantai. RSSI tidak dijadikan meter.

Label **Estimasi horizontal GPS** mempertahankan nilai koordinat mentah. Jika
jarak tersebut <= jumlah radius akurasi HP dan ESP, aplikasi memperingatkan
bahwa jarak dekat belum dapat dibedakan dari ketidakpastian lokasi. Jumlah radius
ini penanda kehati-hatian, bukan batas galat pasti atau interval statistik
gabungan. Jika akurasi sumber tidak diketahui, status itu ditampilkan terpisah.
Jangan mengurangi nilai GPS, menolkan GPS berdasarkan RSSI, atau menyimpulkan
bahwa GPS indoor adalah jarak terukur.

Untuk titik indoor, gunakan meteran/denah berskala dan catat cara pengukurannya.
Jarak 3D dihitung dari `sqrt(horizontal_manual^2 + beda_tinggi_manual^2)` hanya
jika kedua input tersedia. Mengisi beda tinggi saja tidak menghasilkan jarak
3D. GPS altitude dan nomor lantai tidak dipakai untuk menebak tinggi. Pengukuran
manual melekat pada titik selama 60 detik; jangan pindah selama titik berjalan.

### Bluetooth Mati

Di tab UJI JARAK, sebelum pilot berjalan, Bluetooth yang mati dapat memunculkan
dialog persetujuan Android satu kali jika perangkat dan izin mendukung. Ada
tombol **Nyalakan Bluetooth** untuk permintaan ulang secara sadar. Permintaan
dialog bukan bukti Bluetooth sudah menyala; status scanner tetap dibaca dari
native capabilities. Jika pengguna menolak, dialog tidak diulang tiap detik.
Tidak ada dialog otomatis di tengah pilot berjalan; pengamatan yang kehilangan
scanner tetap dibatalkan dengan alasan asli, bukan dianggap sukses.

Ketika radio Bluetooth mati, HP tidak dapat menerima paket BLE sebagai pemicu.
App tidak menyalakan Bluetooth diam-diam dari pesan masuk atau background.
Setelah pengguna menyalakannya, pemulihan scanner/inbox memakai mekanisme native
yang sudah ada. Jika Nearby devices belum diizinkan, berikan izin melalui
pengaturan HP terlebih dahulu.

`Belum ada penerimaan baru` tidak membuktikan pasti di luar jangkauan. Simpan titik
itu juga. PHY **Coded terverifikasi** berasal dari ScanResult aktual; S2/S8 tetap
tidak diketahui. Jangan menyebut titik terjauh sebagai maksimum universal.

## 6. Tunggu Penghentian ESP

Setelah 20 menit, laptop menghentikan sumber dan memeriksa readiness. Harus ada
**`ESP stop confirmed: True`**. HP tidak dapat mengonfirmasi penghentian ESP dari
jauh. Jangan menutup terminal Run atau mencabut USB ESP selama proses berlangsung.

Jika script crash, laptop sleep/mati, COM terputus, atau stop tidak terkonfirmasi,
matikan ESP sebelum mendekatkan HP kembali. Jangan mengubah `source_status.json`
agar terlihat berhasil. Arsipkan kegagalan dan evaluasi sebagai bagian pilot.

## 7. Sambungkan HP Lagi dan Kumpulkan Excel

Setelah Run selesai, sambungkan HP lewat USB, buka kunci, izinkan debugging dan
biarkan app hidup. ESP tidak perlu dibuka COM-nya lagi. Pada terminal yang sama:

```powershell
adb devices -l
powershell -NoProfile -ExecutionPolicy Bypass -File tools\range_test.ps1 -Phase Collect -Serial $Serial -OutputDir $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Collect gagal; jangan reset/clear data HP. Periksa error dahulu' }
Invoke-Item (Join-Path $OutputDir 'resqmesh_range_analysis.xlsx')
```

Jika memakai terminal baru, variabel sebelumnya tidak ada. Inisialisasi dulu,
gunakan **folder Run yang sama**, bukan membuat folder atau sesi baru:

```powershell
Set-Location 'D:\PKM\Project\pkmproject'
$Serial = 'fbde50b6'
$OutputDir = 'D:\PKM\Project\pkmproject\experiment_output\coded-range-YYYYMMDD-HHMMSS'
```

Ganti placeholder dengan folder sebenarnya, kemudian jalankan blok Collect.
Jangan memulai smoke, sesi lain, atau pilot baru di HP sebelum Collect berhasil:
script mencocokkan session/trial HP dengan manifest. Data diekspor sebelum reset
state trial HP. Gagal ekspor tidak menghapus data mentah atau reset HP.

## 8. Baca Hasil dan Tangani Error

Workbook berisi Overview, Source Status, Test Points, RX Samples, GPS Track dan
Diagnostics. Periksa source selesai 20 menit, stop terkonfirmasi, error TX, hasil
tiap titik, RSSI, PHY dan kualitas lokasi. Ringkasan jarak hanya menggunakan RX
sesi dengan lokasi layak. Satu titik bukan trial SOS independen atau DSR baru.

Kolom GPS tetap terpisah dari `measured_horizontal_m`, `height_difference_m`,
`measured_3d_m`, `measurement_method` dan `point_note`. RX dalam window titik
memuat identitas titik dan input manual terkait. RX di luar titik tidak diberi
jarak manual. Ringkasan manual hanya menggunakan titik selesai yang menerima
paket; titik dibatalkan/tanpa penerimaan tidak meningkatkan ringkasan tersebut.
Perkiraan manual tetap berlabel perkiraan, bukan pengukuran presisi otomatis.
Arsip lama tetap dapat diekspor, tetapi jarak manual dan tinggi tidak direka
ulang dari koordinat/RSSI lama. Ringkasan GPS lama tetap tersedia; ringkasan
`farthest_resolved_gps_estimate_m` hanya memakai GPS dengan akurasi sumber
diketahui dan jarak lebih besar dari jumlah radius akurasi.

- **Access denied / COM terkunci:** tutup pemilik serial lama; jangan flash dan
  Run bersamaan. Cabut/pasang ESP hanya ketika tidak ada sesi aktif, cek COM lagi.
- **ADB tidak tersedia setelah USB dilepas:** normal saat Run sudah baseline
  berhasil; Run selanjutnya hanya membaca serial. Collect membutuhkan USB lagi.
- **Trial lama / pilot aktif:** ekspor/finalisasi sesi lama berdasarkan bukti,
  bukan reset paksa. Jangan membuat SOS kedua untuk mencoba memperbaikinya.
- **Baseline timeout:** jangan pergi; cleanup mencoba menghentikan ESP. Jika
  profil pilot dan manifest lengkap, Collect arsip INVALID; jika profil belum
  dibuat, arsipkan/finalisasi melalui Research Monitor.
- **Collect timeout:** cek HP tetap hidup, USB `device`, app dan log; jangan clear
  data atau mengedit hasil. Simpan folder dan error sebelum mencoba recovery.
- **Excel sedang terbuka:** tutup workbook sebelum ekspor ulang.

Log command HP dapat diperiksa setelah USB kembali tersambung:

```powershell
adb -s $Serial logcat -d -v threadtime ResQMeshCommand:I NativeBleManager:D BleWakeUpReceiver:I '*:S'
Get-Content -LiteralPath (Join-Path $OutputDir 'source_status.json')
```

Workbook dapat dibangun ulang dari arsip tanpa perangkat atau trial baru:

```powershell
py tools\experiment_controller\range_report.py --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Ekspor ulang workbook gagal; data mentah tetap disimpan' }
Invoke-Item (Join-Path $OutputDir 'resqmesh_range_analysis.xlsx')
```

## Isi Arsip

- `resqmesh_range_analysis.xlsx`: Overview, Source Status, Test Points, RX Samples,
  GPS Track, Diagnostics; tabel terfilter, header tetap, kolom numerik.
- `range_trial.json`: seluruh lokasi, RX terkait, titik, dan diagnostik pilot.
- `source_status.json`, `source_events.json`, `esp_serial.txt`: bukti sumber dan
  penghentian, termasuk kegagalan; `manifest.json`: identitas/run/build.
- `phone_commands.txt`, `android_trial.json`, `android_trial.csv`: command final
  dan arsip event protokol asal; CSV setiap sheet untuk analisis ulang.

Setiap RX mencantumkan event ID/observation ID asal dan waktu fisik RX. Lokasi
dipasangkan ke waktu RX (selisih maksimal 5 detik), bukan waktu UI membaca data.
RX sebelum sesi adalah baseline; RX sesudah sesi dipertahankan tetapi tidak
menaikkan ringkasan **jarak terjauh teramati**. Kegagalan sumber dilaporkan terpisah
dari `no_receive_observed`; satu titik bukan trial SOS independen atau DSR baru.
Empat rumus metrik penelitian lama tidak berubah.
Pengumpulan menandai trial pilot INVALID jika sumber tidak selesai, penghentian
tidak terkonfirmasi, atau terdapat ADVERTISE_BURST_FAILED. Baseline saja bukan
SUCCESS pengamatan sesi: dibutuhkan RX dalam rentang 20 menit yang dimulai.

Workbook dapat dibuat ulang tanpa perangkat dan tanpa menjalankan trial baru:

```powershell
py tools\experiment_controller\range_report.py --output $OutputDir
```

## Pemeriksaan Implementasi

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_range_test.ps1
py -m pytest tools\experiment_controller\tests
```

Native: jalankan `.\gradlew.bat test` dari folder `android`, dengan JDK
yang digunakan proyek. Test script menggunakan mock, tidak membuka COM/ADB fisik.
Hardware acceptance masih perlu baseline dekat, USB HP dilepas, beberapa titik
diam, penghentian otomatis ESP, lalu kecocokan arsip dan tampilan HP.
