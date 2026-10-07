# Audit Pelaporan Profil Tetangga

Pemeriksaan dimulai 2026-10-07 dan build final selesai 2026-10-08 pada
`D:\PKM\Project\pkmproject`, branch
`metode-penerimaan`, HEAD `2ecdf8bf81f9cb9cbacca17e6f1bf27fae56f664`.
Working tree bersih saat mulai. Implementasi awal sudah di-commit pada HEAD;
perubahan audit ini tidak di-commit/push. Referensi tracking origin dilihat lokal
saja, bukan verifikasi server. Tidak ada install/flash/trial perangkat atau
penghapusan dataset, database, NVS, konfigurasi pribadi, raw log maupun arsip.

## Perubahan Dan Alasan

- Menambahkan `setup_plus_window_tx` tanpa mengganti field/rumus lama. Filter
  session/trial/scope berlaku juga sebelum menentukan SOS/t0; STATUS setup
  tidak masuk overhead window. Identitas burst menduplikasi RF replay/arsip;
  REQUESTED/FAILED tidak dihitung sebagai TX sukses.
- Statistik deskriptif per metode/skenario memasukkan FAILED_DELIVERY yang sah,
  memisahkan INVALID, dan tetap mempertahankan rasio agregat lama. Mean/median/
  SD sampel/min/max serta jumlah nilai terdefinisi tersedia; null tetap kosong.
- Delay pasangan sukses dibedakan dari mean delay per trial. Grafik SVG per
  skenario menampilkan DSR, delay, LDR, overhead, komposisi DATA/STATUS. Delay
  disertai DSR agregat/jumlah pasangan sukses. Tidak ada uji inferensial otomatis.
- Diagnostik memuat INITIAL_FORWARD_FAILED/pending, snapshot pengetahuan
  individual, STATUS kosong/complete, scope keputusan, repair cooldown sekali
  per episode, scanner registration setelah burst. Jalur diagnostic best-effort
  tidak mengubah durable SOS/ACK, pilihan Trickle, payload atau Basic Flooding.
- Validator offline PASS/FAIL/INCONCLUSIVE menilai bukti log per kasus, tidak
  membuka COM/ADB, dan tidak menyamakan mock atau registrasi API dengan RF.
- PHY requested, API accepted, coding support, coding aktual/verifikasi kini
  terpisah pada telemetry, readiness, manifest, UI dan ekspor. SDK Android 36
  diperiksa dengan javap; public AdvertisingSetParameters.Builder tidak punya
  setter S8. Jalur resmi NimBLE HCI V2 ESP yang sudah ada dipertahankan.
  Profil coded tidak diblokir karena S8 belum terverifikasi.

Mekanisme benar yang dipertahankan: initial pada kesempatan Trickle, MISSING
segar mengalahkan HAVE, UNKNOWN/stale bukan HAVE, all-HAVE dapat menekan DATA
tanpa menghapus queue, discovery STATUS kosong, repair cooldown, filter graph
sebelum efek protokol, serta envelope DATA yang sama pada empat metode.

## Pemeriksaan Audit Ini

Hasil berikut benar-benar dijalankan ulang, bukan disalin dari laporan historis:

| Pemeriksaan | Hasil |
| --- | --- |
| dart format . | Lulus |
| dart format --output=none --set-exit-if-changed . | Lulus, 97 file, 0 perubahan |
| flutter analyze | Lulus, No issues found |
| flutter test --reporter expanded | Lulus, 395 tes |
| Gradle testDebugUnitTest | Lulus, 46 tes, 0 failures/errors |
| Python unittest discover | Lulus, 119 tes |
| PlatformIO native | Lulus, 23 tes |
| test_range_test.ps1 | Lulus, 18 pemeriksaan mock |
| test_build_neighbor.ps1 | Lulus, parser/hash/ID/warning/exit code |
| Exporter fixture sintetis | Lulus, workbook + 15 SVG + JSON/CSV |
| Validator CLI pada fixture parsial | Exit 3 yang diharapkan, 74 INCONCLUSIVE, tidak mengakses perangkat |
| git diff --check | Lulus, exit 0 |
| Pasangan build final APK/firmware | Lulus, build ID identik 6987c32b17a1, hash source cocok |
| Firmware esp32c3 final | Lulus, RAM 32416/327680 byte (9.9%), flash 836295/1310720 byte (63.8%) |
| Grafik delay SVG di browser headless | Berhasil dirender dan diperiksa visual, label tidak tumpang tindih |

Log pengujian di `build/neighbor-audit-{flutter,gradle,native,python}-tests.log`.
Log build pertama `build/neighbor-audit-paired-build.log` tidak boleh digunakan
sebagai pasangan final: source CLI diperbaiki setelah tes menemukan kesalahan
dispatch offline; penjaga fingerprint menolak pasangan tersebut. Build final
dijalankan ulang pada source yang dibekukan dan dicatat terpisah di
`build/neighbor-audit-paired-build-final.log`.

Artifact final: `build/neighbor-6987c32b17a1-20261008-000231-149/`, berisi
`app-debug.apk`, `firmware.bin` dan `build_manifest.json`. Hash source juga
diperiksa ulang sesudah build; sesuai manifest. Tidak ada flash atau install.
Screenshot grafik contoh: `build/neighbor-chart-delay-proof.png`.

Tes baru mencakup biaya setup/window, duplikasi burst, session/trial/scope asing,
REQUESTED/FAILED, unequal n, FAILED_DELIVERY, INVALID, null delay/LDR/SD, rasio
agregat vs mean trial, tabel/angka/data mentah/SVG pada data kosong/parsial,
PHY tanpa bukti S8, frekuensi keputusan, bounded cooldown dan offline validator.
Validator diuji pada bukti positif, kontradiksi, kasus tidak teramati, gap arsip,
scanner registration tanpa RX, S1/S2 OFF/ON, expiry sebelum/sesudah refresh,
discovery kosong dengan identitas burst, marker arsip dan hitung ulang metrik.
Seluruh tes protokol sebelumnya ikut berjalan.

## Contoh Data Sintetis

Workbook contoh, **bukan hasil perangkat atau penerimaan hardware**:

`build/neighbor-report-SYNTHETIC-20261007-audit/merged/resqmesh_neighbor_analysis.xlsx`

Ada 10 trial sintetis/71 event; 9 valid (termasuk kegagalan delivery), 1 INVALID,
serta 15 grafik, dengan S1/S2 sengaja kosong untuk menguji null. Folder raw,
manifest dan JSON/CSV dipertahankan. Overview/event/grafik ditandai SYNTHETIC.

Contoh `trickle_neighbor_status`, S0 sintetis: 3 valid, 1 invalid; overhead
window total 6 burst, mean 2 burst/trial; STATUS setup total 3; setup+window
total 9. Delay pasangan sukses 257.143 ms untuk 7 pasangan, sedangkan mean
delay trial dengan RX 225 ms untuk 2 trial. Trial tanpa RX memiliki delay/LDR
kosong. Angka ini hanya menunjukkan perbedaan definisi, bukan keunggulan metode.
Validator menghasilkan INCONCLUSIVE karena fixture ini tidak memuat bukti
mekanisme/arsip fisik lengkap. Tes positif tetap berlabel SYNTHETIC, bukan RF.

## Batas Dan Pekerjaan Fisik

Belum ada penerimaan hardware untuk binary audit ini. Wajib install/flash manual
pasangan build final, pilot keenam node, dan periksa kasus pada
[panduan validator](neighbor_status_windows.md#6-validator-log-dan-kasus-pilot).
Tidak boleh mengganti bukti yang hilang dengan PASS. Kasus cancellation pada
akhir window yang tidak memiliki RX berikutnya tetap INCONCLUSIVE; pilot
diagnostik terpisah mungkin diperlukan. Default parameter bukan optimasi empiris.

Coding on-air tetap UNKNOWN/UNVERIFIED; LE Coded bukan bukti S8/125 kbps.
Frame 17/39/22-86 byte bukan semua overhead RF; burst bukan energi. Graph logis
bukan isolasi RF/jarak fisik. Satu SOS/trial; gateway/completion ACK disabled;
STATUS bukan ACK. Hasil membandingkan mekanisme lengkap, bukan hanya efek STATUS.
Unit analisis, efek blok, asumsi distribusi dan missing belum ditetapkan untuk
uji inferensial. Warning macro NimBLE, Java 8 dependency dan deprecation Gradle
masih perlu dicatat; tidak diperbaiki dengan perubahan protokol yang tak terkait.

## File Audit

```text
README.md
docs/neighbor_status_experiment.md
docs/neighbor_status_validation.md
docs/neighbor_status_windows.md
docs/research_monitor.md
docs/neighbor_reporting_validation.md
tools/experiment_controller/resqmesh_controller/neighbor_experiment.py
tools/experiment_controller/resqmesh_controller/neighbor_reporting.py
tools/experiment_controller/resqmesh_controller/neighbor_validation.py
tools/experiment_controller/resqmesh_controller/cli.py
tools/experiment_controller/tests/test_neighbor_reporting.py
tools/neighbor_report_fixture.py
lib/screen/research_monitor_screen.dart
lib/services/ble_advertiser_service.dart
lib/services/ble_relay_service.dart
lib/services/neighbor_runtime.dart
lib/services/neighbor_status_controller.dart
test/neighbor_transport_test.dart
test/neighbor_queue_integration_test.dart
android/app/src/main/kotlin/com/example/pkmproject/CodedRadioPolicy.kt
android/app/src/main/kotlin/com/example/pkmproject/NativeBleRadio.kt
android/app/src/test/kotlin/id/ac/usu/resqmesh/CodedRadioPolicyTest.kt
firmware/esp32c3/include/NeighborTransport.h
firmware/esp32c3/src/NeighborTransport.cpp
firmware/esp32c3/src/main.cpp
firmware/esp32c3/src/CodedRadio.cpp
firmware/esp32c3/test/test_neighbor/test_main.cpp
```
