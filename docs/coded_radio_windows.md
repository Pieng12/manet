# Uji Extended Coded di Windows 11

## Batas Bukti

Belum ada uji hardware pada perubahan ini. Android memakai public
AdvertisingSet API (API 26+), bukan GATT. OPPO Android 11 dapat memilih Coded
tetapi tidak mengunci S8. ESP hanya menerima require S8 jika supported-command
bit V2 tersedia dan configure controller sukses. ESP32-C3 tidak diasumsikan
mendukung V2: baca readiness aktual. Tidak ada fallback legacy/1M otomatis.

`primary=3 secondary=3` pada Android RX atau `coded` pada status membuktikan
PHY Coded, bukan coding payload S8. Verifikasi coding di udara membutuhkan
sniffer/instrument yang dapat membedakan S2/S8. `on_air_coding_verified=false`
tetap benar sebelum bukti tersebut tersedia.

## Build dan Instalasi

Dari root repository, PowerShell:

```powershell
git branch --show-current
$BuildId = (git rev-parse --short=12 HEAD).Trim()
$env:RESQMESH_BUILD_ID = $BuildId
$env:PLATFORMIO_CORE_DIR = 'D:\pio'
py -m platformio test -d firmware/esp32c3 -e native
py -m platformio run -d firmware/esp32c3 -e esp32c3
flutter analyze
flutter test
flutter build apk --debug --dart-define=RESQMESH_MODE=offline --dart-define=RESQMESH_BUILD_ID=$BuildId
adb devices -l
adb -s <SERIAL_OPPO> install -r build\app\outputs\flutter-apk\app-debug.apk
py -m platformio device list
py -m platformio run -d firmware/esp32c3 -e esp32c3 -t upload --upload-port <COM_ESP>
```

Path pendek `D:\pio` menghindari kegagalan unpack SDK karena MAX_PATH Windows.
Pasang APK dan firmware baru untuk migrasi ini. Jangan upload sebelum memilih
port/serial aktual. Tutup serial monitor sebelum menjalankan controller.
Untuk dataset formal, commit lokal perubahan terlebih dahulu dan build APK
dengan `--dart-define=RESQMESH_BUILD_ID=<SHA12>` serta firmware dari commit yang
sama. Build dari working tree dirty bukan provenance eksperimen final.

## Status dan Konfigurasi

Aktifkan Bluetooth, izin BLE/location Android 11 dan lokasi sistem; matikan
optimisasi baterai OPPO sesuai panduan background yang sudah ada. Buka Research
Monitor > System > Extended Coded Radio. Periksa requested/configured mode,
ready, primary/secondary/scan, interval 250 ms, error dan daya aktual.
Configured mode Android tetap null sampai callback pertama sukses; readiness
awal menunjukkan capability, bukan keberhasilan transmisi.

Firmware menggunakan serial JSON satu baris. Buka monitor:

```powershell
py -m platformio device monitor -b 115200 -p <COM_ESP>
```

Kirim `{"command":"readiness","command_id":"radio-check"}`. Untuk mode
radio, tambahkan `"radio_mode":"coded"` pada command `configure_session`
lengkap di firmware README; gunakan epoch dan role/hop yang sama seperti
sebelumnya. Tidak ada command demo yang mengganti codec atau scheduler.

Salin config.example ke file konfigurasi BARU, isi serial/COM/build ID aktual,
session baru dan `radio_mode=coded`. Jangan menimpa output 90 trial lama.

```powershell
$OutputDir = 'experiment_output\coded-pilot-001'
py tools\experiment_controller\run.py readiness --config experiment.coded.local.json --output $OutputDir
py tools\experiment_controller\run.py smoke --config experiment.coded.local.json --output $OutputDir
adb -s <SERIAL_OPPO> logcat -v threadtime NativeBleAdvertiser:I BleWakeUpReceiver:I '*:S'
```

## Matriks Uji

1. **OPPO -> ESP:** source Android dan destination ESP H1, `coded` keduanya.
   Lulus jika callback Android sukses, SOURCE_FIRST_ADVERTISE_STARTED ada,
   ESP menerima payload RM17 dan destination event cocok message/state.
2. **ESP -> OPPO:** sesi validasi terpisah, ESP SOURCE hop1 dan Android
   DESTINATION expectedHop1. Android RX log harus primary=3 secondary=3,
   legacy=false; satu physical observation tidak menjadi logical accept ganda.
3. **ESP -> ESP:** butuh minimal dua ESP, SOURCE dan DESTINATION. Bandingkan
   packet/CRC/status/timestamp/hop setelah codec; jangan anggap tersedia jika
   hanya satu board terpasang.
4. **Multi-hop:** jalankan smoke H1/H2/H3 dengan testbed lengkap; topology policy
   unchanged. Lulus jika first receive, latency, reset/quiet dan Trickle evidence
   memenuhi validator. Jangan langsung menjalankan 90 trial sebelum smoke baru.
5. **ACK:** sesi gateway/ACK validasi terpisah, bukan main experiment (ACK
   memang disabled di main). Buat SOS lalu ACK RESOLVED dari gateway yang ada.
   ACK harus memakai Coded yang sama, menghentikan SOS dan memiliki dedup/
   tombstone/relay seperti sebelumnya. Tidak menambahkan generator ACK palsu.
6. **Lifecycle:** ulangi saat layar mati/background; lakukan penggantian SOS
   ke ACK, stop saat starting, dan radio off/on. Tidak boleh muncul sukses untuk
   burst dibatalkan, set lama tidak terus TX. Sesudah Bluetooth on, hidupkan
   relay kembali jika OS tidak memulihkannya; scanner benar-benar aktif dan
   payload persistent dapat diteruskan. Catat kegagalan permission/timeout.
7. **S8:** default semua node `coded`. Ubah hanya ESP wajib melalui
   `nodes[].radio_mode="coded_s8_required"`; readiness preflight menuntut V2,
   konfigurasi sebelum trial menuntut requirement accepted. Jika unsupported,
   trial harus ditolak dengan error asli, tidak turun otomatis. Kembalikan
   ESP ke `coded` dengan configure lengkap bila hendak menguji mode biasa.
   Android requiredS8 harus ditolak `S8_SELECTION_UNSUPPORTED`.

Kriteria radio: requested mode jelas, controller configure/start sukses,
interval identik kedua algoritma, TX power aktual dicatat bila tersedia,
scanner pulih setelah gagal TX/burst, application payload tetap17. Simpan
manifest/radio_readiness, log JSON dan workbook dalam sesi baru.

## Pilot Daya Tinggi

Revisi 2026-10-06 menaikkan permintaan daya ESP32-C3 dari +9 ke +20 dBm
dan Android dari -7 ke +1 dBm (`AdvertisingSetParameters.TX_POWER_HIGH`).
Nilai Android ini kompatibel dengan public Extended Advertising API yang
dipakai HP lama kita; bukan jaminan maksimum hardware semua model HP.
Controller tetap menentukan daya terpilih, bukan angka yang dipalsukan oleh app.

Interval radio tetap 250 ms, non-connectable/non-scannable, primary/secondary
Coded, payload 17 byte, durasi burst, Basic, kedua varian Trickle, dedup,
transaksi SOS/ACK dan rumus metrik tetap sama. S8 tidak dipaksa jika unsupported.
Firmware tidak menginisialisasi Wi-Fi; tidak ada scan/koneksi Wi-Fi yang perlu
dimatikan pada jalur sekarang. Daya tinggi tidak berarti kemampuan RX meningkat.

1. Selesaikan dan arsipkan trial aktif sebelum mengganti binary. Jangan mengubah
   daya di tengah batch, menimpa output lama atau menggabungkan data daya lama
   dan baru sebagai kondisi eksperimen yang sama.
2. Bekukan revisi/build ID sebelum dataset formal. Build APK offline dan firmware
   dari revisi yang sama seperti panduan di atas, lalu install APK dan flash
   semua ESP yang akan digunakan. Tidak perlu clear data/NVS atau hapus arsip.
3. Periksa readiness ESP: `radio.ready=true`, `last_error=0`,
   `tx_power_requested_dbm=20`, dan `tx_power_actual_dbm` terisi. Bila nilai aktual
   lebih rendah, laporkan nilai tersebut; jangan mengklaim pemancar +20 dBm.
   Jika konfigurasi/start gagal, hentikan persiapan dan periksa error asli.
4. Android meminta `tx_power_requested_dbm=1`. Daya aktual baru tersedia sesudah
   callback advertising sukses; `null` pada HP yang hanya menjadi DESTINATION
   bukan bukti kegagalan. Uji HP sebagai SOURCE untuk membaca daya aktualnya.
5. Mulai sesi/output pilot baru. Verifikasi baseline dekat HP -> ESP dan
   ESP -> HP dengan identitas SOS yang sesuai, callback sukses dan penerimaan
   PHY aktual Coded. Setelah itu uji titik jarak yang sama, dengan posisi,
   orientasi antena, interval dan algoritma yang sama untuk perbandingan.
6. Simpan readiness/radio telemetry, log mentah dan workbook. Laporkan jarak
   terjauh teramati, bukan jarak maksimum universal. Periksa stabilitas suplai
   daya dan konsumsi daya pada pengujian panjang; tidak ada jaminan tambahan meter.
7. Untuk testbed penuh, ulang smoke sembilan kondisi sebelum batch baru 135 trial.
   Pertahankan setting daya yang sama pada semua metode dan seluruh batch baru.

Daya aktual yang tersedia adalah laporan controller, bukan pengukuran RF dengan
power meter. Memverifikasi S2/S8 di udara tetap membutuhkan alat yang sesuai.
Ikuti ketentuan RF setempat dan batas board/modul; jangan menambah penguat eksternal
atau mengasumsikan daya pada antena sama dengan angka controller.

Referensi: [ESP32-C3 BLE TX characteristics](https://documentation.espressif.com/ESP32-C3_Datasheet_en.pdf),
[Android TX_POWER_HIGH](https://developer.android.com/reference/android/bluetooth/le/AdvertisingSetParameters),
[Android callback daya terpilih](https://developer.android.com/reference/android/bluetooth/le/AdvertisingSetCallback).

## RX PHY dan Pergantian Trial Manual

Scan Coded memakai report delay 0 (tanpa batching), tetap melalui PendingIntent
dan inbox yang sama. Parser batch Android 11 membangun ScanResult memakai
constructor lama yang mengisi primary=1, secondary=0 dan legacy=true. Karena
itu log dari jalur batch lama tidak cukup untuk membuktikan PHY di udara.
Perbaikan ini tidak menulis ulang nilai PHY menjadi Coded: log tetap membaca
ScanResult aktual, ditambah sender_crc, timestamp_compact dan hop untuk
menghubungkan laporan radio dengan packet yang diuji. Uji ulang dengan APK baru
dan scanner yang direstart; firmware tidak perlu diupload ulang untuk koreksi RX
ini. Jika laporan baru masih legacy/1M, Coded di udara tetap belum terbukti.

Jangan memakai readiness primary/secondary sebagai bukti receive: field tersebut
menjelaskan konfigurasi yang diminta. Android DESTINATION boleh memiliki
configured_mode=null dan tx_power_actual_dbm=null jika belum pernah mengiklankan.
Cari DESTINATION_FIRST_VALID_RECEIVE dengan message/state yang sama, selain
primary=3 secondary=3 legacy=false pada laporan RX baru.

Start scan idempoten untuk konfigurasi filter yang sama. Wake/tick service
memakai ulang registrasi aktif, bukan membuat scanner baru setiap panggilan.
Start pertama sesudah proses baru atau perubahan filter menghentikan scan
PendingIntent lama sebelum mendaftar ulang. Start/stop diserialisasi. Receiver
menangani EXTRA_ERROR_CODE sebelum payload; error asinkron membuat scanner=false
dan lastScanErrorCode=SCAN_STATUS_<kode>, tanpa mengubah pemrosesan packet valid.
Log registration accepted menunjukkan request diterima, bukan bukti RX.
Jika sistem telanjur memiliki banyak registrasi dari APK sebelumnya, tutup trial,
reset ESP, restart HP sekali sesudah mengganti APK, lalu ulangi dengan sesi baru.

Reset tidak menutup status trial RUNNING. Sebelum configure sesi lain, tunggu
hasil final ok=true untuk end_observation_window, finalize_trial (hasil sesuai
bukti; INVALID jika setup gagal), export_trial bila diperlukan, lalu reset_trial.
Respons accepted=true hanya tanda command diterima. Gunakan command_id dan
session_id baru saat mengulang setup yang gagal, bukan replay ID lama. Jangan
memulai trial atau trigger SOS jika configure_session gagal.

## Sumber API

- [Android AdvertisingSetParameters.Builder](https://developer.android.com/reference/android/bluetooth/le/AdvertisingSetParameters.Builder)
- [Android ScanSettings.Builder](https://developer.android.com/reference/android/bluetooth/le/ScanSettings.Builder)
- [Android 11 batch scan parser](https://android.googlesource.com/platform/packages/apps/Bluetooth/+/refs/tags/android-11.0.0_r48/src/com/android/bluetooth/gatt/GattService.java)
- [ScanResult legacy constructor defaults](https://android.googlesource.com/platform/frameworks/base/+/beeb7f4/core/java/android/bluetooth/le/ScanResult.java)
- [Apache Mynewt GAP](https://mynewt.apache.org/latest/network/ble_hs/ble_gap.html)
- [NimBLE-Arduino 2.5.1](https://github.com/h2zero/NimBLE-Arduino/tree/2.5.1)
- [NimBLE GAP source: options dan V2 supported commands](https://github.com/h2zero/NimBLE-Arduino/blob/2.5.1/src/nimble/nimble/host/src/ble_gap.c)
- [Bluetooth 5.4 Technical Overview: Advertising Coding Selection](https://www.bluetooth.com/wp-content/uploads/2023/02/2301_5.4_Tech_Overview_FINAL.pdf)
