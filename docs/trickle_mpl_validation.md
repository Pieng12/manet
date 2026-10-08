# Validasi MPL BLE

## Batas Klaim

Implementasi software bukan bukti radio fisik. PASS validator adalah konsistensi
bukti log yang tersedia; INCONCLUSIVE berarti bukti/kasus kurang, bukan PASS
atau delivery gagal. Trace sintetis diberi label, tidak dicampur dataset fisik.
Klaim mekanisme merujuk [RFC 6206](https://www.rfc-editor.org/rfc/rfc6206.html)
dan [RFC 7731](https://www.rfc-editor.org/rfc/rfc7731.html); ekstensi dijelaskan
di [desain](trickle_mpl_design.md).

## Pengujian Otomatis

- `test/mpl_scheduler_test.dart`: listen-only, doubling/c reset, suppression/e,
  duplicate burst/freshness, partial/ambigu, deficit tanpa payload palsu,
  cabang C HAVE/D MISSING, node/scanner ON dan repair D-E, kehilangan start,
  retensi, supersession, dua state/multi-peer, cooldown wake, callback lama.
- `test/mpl_advertiser_callback_test.dart`: native DATA/CONTROL berhasil/gagal,
  relay count durable hanya sukses, callback inventory lama, satu owner,
  prioritas DATA due terhadap CONTROL.
- `firmware/esp32c3/test/test_mpl`: timer/repair setara, buffer, native failure,
  bootstrap/restart, supersession, ambiguity, cabang settled/late join, wrap.
- Fixture codec lama Dart/Kotlin/C++ tetap digunakan tanpa perubahan frame.
- Python `tests/test_mpl_experiment.py`: main135/pilot27/smoke9, blok seimbang,
  provenance/readiness reject artifact lama, parameter/window/fingerprint,
  recovery clock, exporter numeric/tables/raw/control+setup, validator negatif.
- Seluruh test historis tetap dijalankan termasuk canonical RX recovery,
  durable SOS/ACK, sequence completeness dan peer-specific expiry validator.

## Validator

`validate-neighbor` menambahkan MPL_LISTEN_ONLY_AND_BOUNDS, C_K_DECISIONS,
OPPORTUNITY_ACCOUNTING, EXPIRATION_RETAINS_BUFFER, EXPIRATION_AND_DOUBLING,
NATIVE_INSIDE_INTERVAL, PHYSICAL_FRESHNESS, REPAIR_BOUNDS,
REPAIR_RESET_STORM, REPAIR_PEER_EVIDENCE dan SEMANTICS_PROVENANCE.
Interval menggunakan selisih wrap-safe; native alias bukan overhead baru.
Log timer incomplete tidak dapat PASS. Expiry historis tetap observer-peer-
episode tertentu; ESP tanpa sequence tidak dapat LOG_COMPLETENESS PASS.
Tidak ada validator yang membuktikan RF tidak mengalami loss dari log saja.

## Pemeriksaan Lokal

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
Push-Location android
.\gradlew.bat test
Pop-Location
$env:PLATFORMIO_CORE_DIR='D:\pio'
py -m platformio test -d firmware/esp32c3 -e native
Push-Location tools/experiment_controller
py -m unittest discover -s tests
Pop-Location
.\tools\build_neighbor.ps1
```

Hasil aktual dan artifact pasangan dicatat pada bagian Hasil Lokal di bawah.
Tidak menggunakan hasil tes commit lama sebagai bukti check baru. Warning
dependency/toolchain dipisahkan dari error/failure test.

## Acceptance Fisik Yang Belum Dijalankan

1. Install/flash manual artifact pasangan dan periksa build ID/semantik semua
   perangkat; baseline dekat berhasil pada Coded PHY yang dilaporkan aktual.
2. Smoke 9 kondisi dengan 180 s; baca raw, INVALID reasons dan Log Validation.
3. S1 D scan OFF/ON dan S2 E TX/RX OFF/ON harus confirmed; trial/state tidak
   di-reset saat ON. Cari MPL_DISCOVERY dan repair cabang setelah ON.
4. Uji diagnostik terpisah untuk kehilangan STATUS/DATA, restart/incarnation,
   native failure, settled timer/buffer, partial snapshot jika belum teramati.
5. Pilot 27: DSR, delay, LDR, DATA, CONTROL, total/setup dan recovery bersama;
   gagal sah tetap data. Jangan mengulang trial hanya agar overhead menang.
6. Bekukan source/build/config/seed sebelum utama135. Jangan menyatakan S8,
   jarak fisik tiga hop, atau konsumsi energi dari hitungan burst.

## Hasil Lokal

Pemeriksaan dijalankan pada 8 Oktober 2026, branch MPL, working tree belum
di-commit. Ini hasil software lokal, bukan hasil perangkat fisik:

| Pemeriksaan | Hasil aktual |
| --- | --- |
| dart format --output=none --set-exit-if-changed . | PASS, 103 file, 0 perubahan |
| flutter analyze | PASS, No issues found |
| flutter test | PASS, 448 test |
| Gradle test | PASS, debug 50, profile 46, release 46; failure/error 0 |
| PlatformIO native | PASS, 42 kasus: MPL 14, neighbor 12, protocol 16 |
| Python unittest discover -s tests | PASS, 156 test |
| Build pasangan tools/build_neighbor.ps1 | PASS, firmware ESP32-C3 dan APK debug |
| git diff --check | PASS |

Test baru mencakup timer stopped yang tetap memiliki waktu bangun di masa
depan setelah runtime dua hari, serta episode repair pada event sukses yang
dapat diverifikasi lintas exporter/validator. Validator menolak budget sukses
yang berulang/tidak meningkat; bukti episode hilang tetap INCONCLUSIVE.

Warning toolchain masih ada: deprecation Flutter/Android/Gradle, redefinisi
CONFIG_BT_NIMBLE_TRANSPORT_EVT_SIZE pada dependency NimBLE, dan Windows long
paths nonaktif. Warning bukan failure test, tetapi bukan bukti kestabilan RF.
Tidak mengubah dependency atau registry Windows untuk menghilangkan warning.

Artifact final: `build/neighbor-b848eb5f59da-20261008-172423-310/`.
Build ID `b848eb5f59da` diperiksa langsung pada kernel debug APK dan binary
firmware. Source SHA pada build_manifest.json cocok dengan FingerprintOnly
setelah build selesai. Artifact sebelum build ID ini bukan pasangan final
pekerjaan ini; arsipnya tetap dibiarkan, tidak dihapus.

| Artifact | SHA256 |
| --- | --- |
| app-debug.apk | 372733577c2491770175f03ba02440a15e041739993f3e4db2698b968aacd284 |
| firmware.bin | 97acb7801a9de90928a0c7701aff8212c13682fe3d6fe9d9025fade11cc2e605 |

Folder juga berisi bootloader.bin, partitions.bin, firmware.factory.bin dan
build_manifest.json. Tidak ada install, flashing, atau batch perangkat fisik
yang dijalankan dalam pekerjaan ini. Pengurangan overhead, DSR/recovery nyata
dan PHY on-air tetap harus diverifikasi melalui acceptance fisik.

## File Yang Diubah Atau Ditambahkan

Daftar pekerjaan lokal pada branch MPL, tanpa commit/push:

```text
README.md
android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt
android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleInboxWorker.kt
android/app/src/test/kotlin/id/ac/usu/resqmesh/NeighborTransportTest.kt
docs/trickle_mpl_design.md
docs/trickle_mpl_validation.md
docs/trickle_mpl_windows.md
firmware/esp32c3/include/MplScheduler.h
firmware/esp32c3/include/NeighborTransport.h
firmware/esp32c3/src/NeighborTransport.cpp
firmware/esp32c3/src/main.cpp
firmware/esp32c3/test/test_mpl/test_main.cpp
lib/config/mesh_config.dart
lib/screen/research_monitor_screen.dart
lib/services/android_experiment_command_service.dart
lib/services/ble_advertiser_service.dart
lib/services/ble_relay_service.dart
lib/services/experiment_export_service.dart
lib/services/experiment_logger.dart
lib/services/mpl_scheduler.dart
lib/services/neighbor_runtime.dart
lib/services/relay_queue_service.dart
test/mpl_advertiser_callback_test.dart
test/mpl_scheduler_test.dart
tools/build_neighbor.ps1
tools/experiment_controller/config.mpl.main.example.json
tools/experiment_controller/config.mpl.pilot.example.json
tools/experiment_controller/resqmesh_controller/excel_report.py
tools/experiment_controller/resqmesh_controller/mpl_config.py
tools/experiment_controller/resqmesh_controller/mpl_validation.py
tools/experiment_controller/resqmesh_controller/neighbor_experiment.py
tools/experiment_controller/resqmesh_controller/neighbor_reporting.py
tools/experiment_controller/resqmesh_controller/neighbor_validation.py
tools/experiment_controller/tests/test_mpl_experiment.py
```

Baseline `trickle_scheduler.dart`, `TrickleTiming.h`, `forwarding_policy.dart`,
database schema dan AndroidManifest tidak diubah. Config pribadi, database,
dataset lama dan artifact lama tidak dihapus atau ditimpa.
