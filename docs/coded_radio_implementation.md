# Extended Coded Implementation

Branch kerja: `feature/coded-extended-advertising`, dari `trickle` pada
`6f6ba5473c0ee167497db38cc849a6563dcea623`. Tidak melakukan push, merge,
upload firmware, instalasi APK, penghapusan dataset atau perubahan config lokal.
`experiment.smoke.local.json` sudah dirty sebelum pekerjaan ini dan dibiarkan.

## Implementasi

- Android memakai satu pemilik AdvertisingSet, primary/secondary Coded,
  non-connectable/non-scannable, manufacturer data 17 byte. Generation guard
  menyelesaikan pending callback sekali, melepas set lama saat timeout/stop/
  replacement, dan menolak late success. MethodChannel tetap mengembalikan
  boolean sukses hanya setelah callback; scheduler Dart dan durasi burst tidak
  diubah. MainActivity, service dan worker memakai pemilik yang sama.
- PendingIntent scan mengatur extended/non-legacy dan Coded, mempertahankan
  filter RM/manufacturer, waktu receive/inbox/dedup, serta memeriksa return code
  startScan. Log RX Android mencatat PHY yang dilaporkan ScanResult.
- ESP adapter memiliki satu instance GAP, memakai extended configure/data/
  start/stop, bukan advertising wrapper paralel. Manufacturer buffer memuat
  FF FF sekali lalu RM17. Scanner NimBLE2 memakai passive extended Coded.
  Scanner dipulihkan sesudah kegagalan TX dan akhir burst.
- Require S8 memakai primary/secondary options0x04 hanya sesudah pemeriksaan
  supported-command bit V2 yang dipakai NimBLE. 0x02 adalah prefer, bukan
  require. Gagal configure/unsupported membuat readiness gagal, tanpa fallback;
  request wajib juga tersimpan di NVS agar restart tidak diam-diam menurunkan
  mode. Kode return GAP/controller tersimpan pada radio.last_error.
- Radio interval 400 units =250 ms, sama untuk Basic/Trickle. Implementasi awal
  meminta TX medium -7 dBm pada Android dan +9 dBm pada ESP. Revisi daya tinggi
  2026-10-06 meminta TX high +1 dBm pada Android dan +20 dBm pada ESP. Selected TX power
  dicatat dari callback/configure, tidak diasumsikan dari enum.
- Telemetry request/configured/coding/acceptance/actual power/error masuk
  readiness, status, Research Monitor, RADIO_CONFIGURED event, manifest dan
  workbook. Config eksplisit masuk fingerprint; historical dataset tidak
  ditulis ulang. Override radio per node memungkinkan ESP requireS8 sementara
  OPPO coded. Readiness menolak ketidakcocokan sebelum trial.

Tidak mengubah Protocol.cpp/.h, payload17/epoch/status/hop, database, durable
SOS/ACK, forwarding policy, relay queue, gateway, topology, Basic scheduler
atau Trickle scheduler (8000/256000/k1).

## Dependency

- Platform pioarduino zip `55.03.312-1` (laporan platform `55.3.312`).
- Arduino ESP32 `3.3.12`, library ESP-IDF `5.5.5+sha.b774170ff46`.
- NimBLE-Arduino `2.5.1`, ArduinoJson `7.3.1`.
- GCC RISC-V `14.2.0+20260121` dari platform terpilih.
- Tidak mencampur Bluedroid. Build Windows memakai core dir pendek `D:\pio`
  karena unpack di default user directory gagal pada batas MAX_PATH.

## File Diubah

Android native (folder `android/app/src/main/kotlin/com/example/pkmproject/`,
package tetap `id.ac.usu.resqmesh`):

- `NativeBleAdvertiser.kt`
- `NativeBleManager.kt`
- `CodedRadioPolicy.kt` (baru)
- `NativeBleRadio.kt` (baru)
- `MainActivity.kt`
- `MeshBackgroundService.kt`
- `BleWakeUpReceiver.kt`
- `android/app/src/test/kotlin/id/ac/usu/resqmesh/CodedRadioPolicyTest.kt` (baru)
- `android/app/src/test/kotlin/id/ac/usu/resqmesh/NativeBleRuntimeTelemetryTest.kt`

Firmware:

- `firmware/esp32c3/platformio.ini`
- `firmware/esp32c3/include/RadioConfig.h` (baru)
- `firmware/esp32c3/include/CodedRadio.h` (baru)
- `firmware/esp32c3/src/CodedRadio.cpp` (baru)
- `firmware/esp32c3/src/main.cpp`
- `firmware/esp32c3/test/test_protocol/test_main.cpp`
- `firmware/esp32c3/README.md`

Flutter:

- `lib/config/mesh_config.dart`
- `lib/services/native_bridge_service.dart`
- `lib/services/android_experiment_command_service.dart`
- `lib/screen/research_monitor_screen.dart`
- `test/android_experiment_command_service_test.dart`
- `test/p5_android_lifecycle_source_test.dart`

Controller (folder `tools/experiment_controller/`):

- `config.example.json`
- `resqmesh_controller/config.py`
- `resqmesh_controller/controller.py`
- `resqmesh_controller/radio.py` (baru)
- `resqmesh_controller/excel_report.py`
- `tests/test_radio.py` (baru)
- `tests/test_controller.py`
- `tests/test_repository_contract.py`

Dokumentasi:

- `README.md`
- `DOKUMENTASI_RESQMESH_BLE.md`
- `docs/experiment_protocol.md`
- `docs/proposal_alignment_android.md`
- `docs/coded_radio_windows.md` (baru)
- `docs/coded_radio_implementation.md` (baru, laporan ini)

## Validasi

- Format check: 86 Dart files, 0 changed.
- Flutter analyze: No issues found.
- Flutter test: 301 passed (diulang sesudah koreksi RX dan registrasi scan).
- Gradle assembleDebug dan testDebugUnitTest: BUILD SUCCESSFUL; 29 Kotlin tests,
  0 failures/errors (4 radio lifecycle/capability/scan, 16 inbox/codec, 9 telemetry;
  diulang sesudah koreksi RX dan registrasi scan).
- Firmware native codec: 10 passed, termasuk manufacturer SOS/ACK dan S8 options.
- Python controller: 49 passed, termasuk radio validation, config propagation,
  readiness snapshot, fingerprint dan regresi merger/workbook.
- Firmware ESP32-C3: SUCCESS; RAM32080/327680 bytes (9.8%),
  flash803153/1310720 bytes (61.3%). Binary firmware.bin874480 bytes.

## Batas dan Uji Perangkat

### Koreksi Metadata RX Android (2026-10-02)

Pada uji manual ESP SOURCE -> Android DESTINATION, export trial
`coded-reverse-20261002-053226-T001` menunjukkan 19 BLE_PACKET_RECEIVED,
1 BLE_PACKET_ACCEPTED, 1 DESTINATION_FIRST_VALID_RECEIVE dan 18 duplicate,
dengan sender_crc4044902222 dan protocol_timestamp_ms1790894198000. Ini
membuktikan penerimaan protokol, bukan coding/PHY di udara.

Log RX lama tetap primary1/secondary0/legacy=true meskipun konfigurasi Coded.
Jalur scan memakai reportDelay1000; parser batch AOSP Android11 menggunakan
constructor ScanResult lama yang mengisi metadata legacy/1M. Ini adalah
penjelasan yang konsisten dengan gejala, bukan verifikasi stack vendor OPPO.
Scan sekarang memakai SCAN_REPORT_DELAY_MS=0 melalui PendingIntent yang sama.
Log RX tetap memakai PHY/isLegacy dari ScanResult, ditambah sender_crc,
timestamp_compact dan hop, tanpa memalsukan metadata menjadi Coded.

Ditambah satu Kotlin test policy dan satu Dart source-contract regression.
Tidak mengubah firmware, payload, filter, RX time validation, durable inbox,
database, forwarding, Basic atau Trickle. Koreksi ini perlu APK baru dan
uji perangkat ulang; tidak membutuhkan flash ESP. Build manual memakai label
`coded-rx-unbatched-local`, bukan SHA provenance dataset formal.

Format check (86 files, 0 changed), analyze, 300 Flutter tests, 27 Kotlin tests
dan build APK lulus pada koreksi batching pertama. SHA256 APK saat itu
`1CDEE9991D37C796584EC4AEA6D3562A2D74A19F2F73EA79D2474340CF7FA328`.
Hasil Python/controller dan firmware di atas berasal dari validasi awal;
keduanya tidak diubah pada koreksi ini. APK tersebut kemudian diuji pengguna;
versi terbaru digantikan oleh koreksi registrasi scan di bawah.

Urutan manual antar-sesi juga dikoreksi di panduan: end_observation_window,
finalize_trial, export bila perlu, reset_trial, lalu configure sesi baru.
Reset saja tidak menutup status RUNNING. Jangan melanjutkan trial setelah
configure gagal meskipun start_trial mengembalikan ok.

### Koreksi Registrasi Scan Berulang

Sesudah restart, readiness Android berhasil tetapi dumpsys Bluetooth kembali
menunjukkan banyak registrasi ResQMesh sementara service mengulangi start scan.
NativeBleManager sekarang memakai ulang registrasi untuk konfigurasi filter
yang sama, menyerialisasi start/stop, dan menghentikan PendingIntent lama sebelum
start pertama pada proses baru atau perubahan filter. Scan yang sama tidak
didaftarkan kembali pada setiap wake/tick service.

BleWakeUpReceiver juga menangani EXTRA_ERROR_CODE sebelum membaca daftar packet.
Kegagalan asinkron dicatat sebagai SCAN_STATUS_<kode>, membersihkan status scan
aktif dan konfigurasi reuse, sehingga readiness tidak terus mengklaim scanner
aktif setelah callback error. Nilai startScan0/log registration accepted tetap
hanya bukti request diterima, bukan bukti receive atau PHY di udara.

Ditambah dua Kotlin tests reuse/error telemetry dan satu Dart source-contract
test. Build manual koreksi ini berlabel `coded-rx-single-scan-local`; tidak
mengubah firmware, protocol, durable inbox, database atau scheduler.

Verifikasi terbaru: format86 files0 changes, analyze bersih, Flutter301 passed,
Kotlin29 passed0 failures/errors, build APK berhasil. APK terbaru ada di
`build/app/outputs/flutter-apk/app-debug.apk`, SHA256
`A7AAA47BD55144D6833FB7D2FA8FFD52EFD5D262F76EC46192932A771E91EBC8`.
APK registrasi scan ini belum diinstal oleh agent; uji RX Coded masih diperlukan.

Build/test bukan uji radio fisik. OPPO public API memilih Coded, tidak mengekspos
advertising S8 coding options. ESP32-C3 belum terbukti mendukung HCI V2 pada
perangkat pengguna; jika unsupported, required mode memang gagal. On-air
coding tetap unverified untuk keduanya, termasuk sesudah callback berhasil.

Compiler mengeluarkan warning redefinition ukuran event transport NimBLE
(SDK default70, library extended257) serta beberapa warning/deprecation Gradle
yang tidak menghentikan build. Tidak mengedit SDK atau vendor library untuk
menyembunyikan warning. Interoperabilitas/controller harus diuji pada hardware.

Artefak working tree ini untuk validasi implementasi, bukan provenance final
dataset. Untuk eksperimen formal: commit lokal terlebih dahulu, bangun kedua
binary dengan SHA sama, lakukan smoke Coded baru, gunakan session/output baru.
Jangan menggabungkan dataset legacy90 trial dengan dataset PHY baru.

Panduan perangkat dan referensi resmi ada di
[Uji Extended Coded Windows](coded_radio_windows.md).
