# Hasil Implementasi Profil Tetangga

Tanggal pemeriksaan: 2026-10-07. Repository lokal: `D:\PKM\Project\pkmproject`.
Branch: `metode-penerimaan`, dibuat dari `optimasi-jarak`.
HEAD yang diperiksa pada audit pelaporan: `2ecdf8bf81f9cb9cbacca17e6f1bf27fae56f664`.
Implementasi awal sudah ada dalam commit tersebut. Branch lokal melacak
`origin/metode-penerimaan` menurut referensi Git lokal; audit ini tidak mengambil
atau memverifikasi keadaan server remote. Saat audit awal berakhir, perubahan
audit pelaporan belum di-commit oleh pelaksana audit. Pemeriksaan lokal pada
2026-10-08 menunjukkan audit pelaporan kini ada dalam commit
`9f64571480705641dc78c9798abadf02b5f4169d`; status push tidak diverifikasi.
Koreksi validator sesudah commit tersebut dicatat terpisah dalam laporan
di bawah. Tidak ada push, flash, install, atau eksperimen fisik oleh audit ini.

Hasil audit terbaru dicatat terpisah dalam
[audit pelaporan dan validator](neighbor_reporting_validation.md). Angka/build
di bagian historis berikut bukan hasil menjalankan ulang audit terbaru.

## Ruang Lingkup

- Mode keempat `trickle_neighbor_status` memakai HAVE/MISSING/UNKNOWN lokal,
  initial forwarding di kesempatan Trickle, dan repair yang dibatasi cooldown.
- DATA RN berversi digunakan bersama pada empat metode dalam profil baru.
  Inner SOS RM tetap 17 byte; DATA total 39 byte, STATUS 22-86 byte.
- Graph S-A, S-B, A-C, B-C, A-D, D-E; semua lima ESP penerima dan relay.
- S0 utama, S1 delayed RX, S2 late join; partisipasi mengontrol scan/TX nyata,
  bukan simulasi dengan membuang paket saat scan dinyatakan aktif.
- Controller mengacak blok, menyinkronkan clock per trial, dan mempertahankan
  FAILED_DELIVERY dalam denominator. Raw attempt tidak ditimpa saat resume.
- Metrik all-node dan workbook `resqmesh_neighbor_analysis.xlsx` terpisah dari
  metrik/workbook lama. Tidak ada pengubahan dataset/config pribadi.
- Pemilik BLE Android yang sama menangani DATA, STATUS, dan recovery inbox
  profil graph. Worker legacy tetap memakai jalur headless yang sudah ada.
- DB protokol tetap versi 14. Tidak ada hard TTL/hop/max relay count baru.

## Pemeriksaan Otomatis Historis

| Pemeriksaan | Hasil |
| --- | --- |
| dart format --output=none --set-exit-if-changed . | Lulus; 97 file, 0 berubah |
| flutter analyze | Lulus; No issues found |
| flutter test | Lulus; 393 tests |
| Gradle testDebugUnitTest | Lulus; 45 tests, 0 failures/errors |
| Python unittest controller/exporter | Lulus; 103 tests |
| PlatformIO native | Lulus; 22 tests |
| test_range_test.ps1 | Lulus; 18 checks perangkat mock |
| test_build_neighbor.ps1 | Lulus; parser/hash/build ID/warning/exit code |
| PlatformIO esp32c3 firmware build | Lulus; RAM 9.9%, flash 63.6% |
| Flutter APK debug, offline + build ID | Lulus |
| git diff --check | Lulus; warning line ending Git bukan whitespace error |

## Artifact Build Historis

Build ID APK dan firmware: `a72f3087f909`. Hash source akhir cocok dengan
manifest. Artifact ada di:

`build/neighbor-a72f3087f909-20261007-025022-698/`

- `app-debug.apk` (199575857 byte).
- `firmware.bin` (908944 byte).
- `build_manifest.json` mencatat hash source dan commit referensi, bukan klaim
  working tree sudah di-commit.

Log lengkap: `build/neighbor-paired-build.log`.
Warning yang masih terlihat: macro NimBLE transport event size dari SDK/library,
Java source/target 8 pada dependency, dan API/fitur Gradle deprecated. Build tetap
exit 0; validasi RF/margin hardware tetap wajib, bukan ditutupi oleh build lulus.

## Cakupan Test

Test membuktikan golden vectors lintas bahasa, frame rusak, HAVE/MISSING
bersamaan, UNKNOWN/partial/stale/scope, initial failed start mempertahankan
queue, suppression tidak menghapus pesan, reset storm dibatasi, perubahan
HAVE tidak mereset karena MISSING lain yang tidak berubah, tombstone tidak
diperbaiki mundur, discovery/expiry, empty STATUS/imminent DATA, native inbox
replay/MAC/first physical time, incarnation/wrap, filter graph sebelum efek,
DSR 80%, null LDR/failed latency, CONTROL overhead/setup, clock bound,
60/180 balanced plans, FAILED_DELIVERY/resume, workbook angka/tabel/raw.
Test baseline/protokol dan Uji Jarak yang sebelumnya ada ikut dijalankan.

Wrapper build menerima warning stderr Windows PowerShell, tetapi tetap menolak
exit code bukan nol. Test memanggil proses native nyata untuk dua kasus itu;
tidak menyamakan warning compiler dengan build gagal.

## Validasi Fisik Belum Dilakukan

Belum ada bukti bahwa keenam perangkat dengan binary baru sudah berhasil
melakukan discovery/repair atau memberi hasil statistik. Unit/integration test
dan build tidak membuktikan scanner/radio RF berjalan kontinu atau pemulihan
setelah native radio gagal pada hardware.

Ikuti [panduan Windows](neighbor_status_windows.md) untuk install/flash manual,
readiness dan smoke/pilot. Checklist penerimaan RF ada di
[spesifikasi implementasi](neighbor_status_experiment.md).
Pastikan native scan D dan TX/RX E benar OFF/ON, queue tetap persisten,
scanner pulih setelah gagal/batal/selesai, dan DATA tidak kelaparan karena STATUS.
Nilai default pilot bukan hasil optimasi empiris; jangan langsung menjalankan
60/180 trial tanpa memeriksa hasil pilot dan membekukan parameter/build.

Coded bukan bukti S8; graph software bukan isolasi/jarak hop RF fisik.
Ringkasan network-wide pada HP berasal dari controller setelah penggabungan,
bukan oracle yang diberikan kepada algoritma. Statistik lokal HP berbeda.
Tidak ada klaim efisiensi energi, novelty global atau keberhasilan rescue.

## File Implementasi Awal

Daftar historis implementasi awal mencakup source, konfigurasi contoh, test, dan dokumentasi;
build artifact/log berada di direktori ignored `build/`, bukan dataset.

```text
README.md
android/app/src/main/kotlin/com/example/pkmproject/BleWakeUpReceiver.kt
android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt
android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleAdvertiser.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleInbox.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleInboxWorker.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleManager.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleRadio.kt
android/app/src/main/kotlin/com/example/pkmproject/NeighborTransport.kt
android/app/src/main/kotlin/com/example/pkmproject/ResearchParticipation.kt
android/app/src/test/kotlin/id/ac/usu/resqmesh/NeighborTransportTest.kt
docs/neighbor_status_experiment.md
docs/neighbor_status_validation.md
docs/neighbor_status_windows.md
docs/research_monitor.md
firmware/esp32c3/include/CodedRadio.h
firmware/esp32c3/include/NeighborTransport.h
firmware/esp32c3/platformio.ini
firmware/esp32c3/src/CodedRadio.cpp
firmware/esp32c3/src/NeighborTransport.cpp
firmware/esp32c3/src/main.cpp
firmware/esp32c3/test/test_neighbor/test_main.cpp
lib/config/mesh_config.dart
lib/main.dart
lib/screen/research_monitor_screen.dart
lib/services/android_experiment_command_service.dart
lib/services/ble_advertiser_service.dart
lib/services/ble_relay_service.dart
lib/services/native_bridge_service.dart
lib/services/neighbor_runtime.dart
lib/services/neighbor_status_controller.dart
lib/services/neighbor_transport.dart
lib/services/relay_queue_service.dart
lib/services/topology_policy.dart
test/android_experiment_command_service_test.dart
test/ble_transport_idempotency_test.dart
test/neighbor_queue_integration_test.dart
test/neighbor_transport_test.dart
test/p6_native_android_source_test.dart
tools/build_neighbor.ps1
tools/experiment_controller/config.neighbor.full.example.json
tools/experiment_controller/config.neighbor.main.example.json
tools/experiment_controller/resqmesh_controller/cli.py
tools/experiment_controller/resqmesh_controller/config.py
tools/experiment_controller/resqmesh_controller/controller.py
tools/experiment_controller/resqmesh_controller/devices.py
tools/experiment_controller/resqmesh_controller/log_merge.py
tools/experiment_controller/resqmesh_controller/neighbor_experiment.py
tools/experiment_controller/tests/test_devices.py
tools/experiment_controller/tests/test_neighbor_experiment.py
tools/experiment_controller/tests/test_repository_contract.py
tools/test_build_neighbor.ps1
```
