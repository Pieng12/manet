# Laporan Implementasi Tiga Metode

## Hasil

- Branch kerja: optimasi-jarak. Tidak ada commit, merge, push, install atau flash.
- Tidak ditemukan AGENTS.md pada repository atau direktori induk yang diperiksa.
- Mesin Trickle bersama, flag suppression; Basic/payload 17 byte/ACK persisten tetap.
- Parameter diaudit: Imin 8 s, Imax 256 s (5 penggandaan), k=1, burst 2 s.
- Manifest lokal: experiment_output/three-methods-plan-20261003/manifest.json.
  Tepat 135 target, 15 per sembilan kondisi, 15 blok acak, seed 20261003, 0 measured.
- Konfigurasi baru: experiment.three_methods.local.json. Konfigurasi/dataset lama tidak diubah.
- Workbook menambah parameter, suppression, actual RX PHY, dua perbandingan deskriptif,
  empat grafik tiga metode dan nomor blok; empat rumus utama tidak berubah.
- Smoke memakai session terpisah dari main; config BOM PowerShell dapat dibaca.
- Informasi PHY adalah laporan API penerima, bukan inferensi dari requested mode;
  S2/S8 tetap tidak diketahui. Database protokol tetap versi 14.

## Pemeriksaan

| Pemeriksaan | Hasil |
| --- | --- |
| dart format --output=none --set-exit-if-changed . | Lulus, 90 file, 0 perubahan |
| flutter analyze | Lulus, No issues found |
| flutter test | 330 lulus |
| pytest tools/experiment_controller/tests -q | 72 lulus |
| android/gradlew.bat test | BUILD SUCCESSFUL, 35 per varian debug/profile/release, 105 eksekusi, 0 gagal/error |
| PlatformIO test -e native | 14 lulus |
| PlatformIO run -e esp32c3 | SUCCESS |
| flutter build apk --debug (offline, SHA 9bb25d4d3eff) | Berhasil |
| git diff --check | Lulus |

Peringatan toolchain yang masih ada: deprecated Android/Gradle API serta
redefinition macro transport NimBLE; bukan error build. Binary lokal mengandung
working tree baru tetapi SHA HEAD lama. Bekukan revisi melalui commit manual,
lalu build/install/flash ulang sebelum dataset resmi. APK:
build/app/outputs/flutter-apk/app-debug.apk. Firmware:
firmware/esp32c3/.pio/build/esp32c3/firmware.bin.

## Cakupan Tes Baru

- Varian dengan/tanpa suppression pada c<k dan c>=k, interval [I/2,I), doubling,
  cap, reset, deduplikasi observasi dan cleanup.
- Queue no-suppression tetap menghitung c, mengirim hop 63/pesan berumur lama,
  dan berhenti pada ACK; parser/research readiness menerima identifier baru.
- 135 identitas unik, 15 kondisi per kombinasi, blok lengkap, seed deterministik,
  replacement invalid tanpa mengubah blok awal, failed delivery tetap valid.
- Metadata keputusan/timing kedua varian, zero suppression smoke sah, session
  terpisah dan konfigurasi Windows BOM, rasio agregat vs rata-rata rasio trial.
- Workbook angka/boolean/null, actual PHY, tabel parameter, dua perbandingan,
  empat grafik dengan tiga series, arsip ZIP dan raw data.
- Telemetry native hanya ketika research aktif, idempoten, memakai actual PHY,
  best-effort setelah durable inbox; failure tidak menghentikan protokol.

## Batas Verifikasi

Tidak ada pengujian hardware baru yang dijalankan. Belum membuktikan smoke
sembilan kondisi atau seluruh 135 trial fisik. Hop adalah filter logis, bukan
isolasi RF/jangkauan universal. Tidak menghasilkan data eksperimen atau p-value.
Tes sintetis berada di tests/temp, bukan dataset pengguna.

Panduan lengkap build, flash/install, discover, plan, readiness, smoke, batch,
resume, Excel, validasi perangkat dan catatan metode proposal:
[three_method_experiment.md](three_method_experiment.md).

## File Diubah atau Ditambahkan

- `README.md`
- `android/app/src/main/kotlin/com/example/pkmproject/BleWakeUpReceiver.kt`
- `android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt`
- `android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt`
- `docs/experiment_protocol.md`
- `docs/physical_smoke_test.md`
- `docs/research_monitor.md`
- `firmware/esp32c3/README.md`
- `firmware/esp32c3/include/TrickleTiming.h`
- `firmware/esp32c3/src/main.cpp`
- `firmware/esp32c3/test/test_protocol/test_main.cpp`
- `lib/config/mesh_config.dart`
- `lib/screen/research_monitor_screen.dart`
- `lib/services/android_experiment_command_service.dart`
- `lib/services/ble_advertiser_service.dart`
- `lib/services/ble_relay_service.dart`
- `lib/services/experiment_export_service.dart`
- `lib/services/experiment_logger.dart`
- `lib/services/native_bridge_service.dart`
- `lib/services/relay_queue_service.dart`
- `lib/services/trickle_scheduler.dart`
- `test/android_experiment_command_service_test.dart`
- `test/relay_queue_service_test.dart`
- `test/trickle_scheduler_test.dart`
- `tools/experiment_controller/README.md`
- `tools/experiment_controller/config.example.json`
- `tools/experiment_controller/resqmesh_controller/cli.py`
- `tools/experiment_controller/resqmesh_controller/config.py`
- `tools/experiment_controller/resqmesh_controller/controller.py`
- `tools/experiment_controller/resqmesh_controller/excel_report.py`
- `tools/experiment_controller/resqmesh_controller/log_merge.py`
- `tools/experiment_controller/tests/test_controller.py`
- `tools/experiment_controller/tests/test_log_merge.py`
- `android/app/src/main/kotlin/com/example/pkmproject/ResearchRxTelemetry.kt`
- `android/app/src/test/kotlin/id/ac/usu/resqmesh/ResearchRxTelemetryTest.kt`
- `docs/three_method_experiment.md`
- `experiment.three_methods.local.json`
- `tools/experiment_controller/resqmesh_controller/comparisons.py`
- `tools/experiment_controller/tests/test_three_methods.py`
- `docs/three_method_implementation_report.md`

Manifest/output build yang disebut di atas adalah artefak lokal terpisah;
arsip smoke/90 trial sebelumnya tidak disentuh.
