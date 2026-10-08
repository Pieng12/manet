# Pilot STATUS adaptif v2

Perubahan hanya aktif pada `trickle_neighbor_status` dengan pilihan eksplisit
`neighbor_status_policy: adaptive_v2`. Konfigurasi tanpa pilihan itu tetap memakai
`periodic_v1` (STATUS 12 detik, freshness 45 detik). Basic Flooding, Trickle lengkap,
Trickle tanpa suppression, aturan waktu DATA Trickle dan payload SOS 17 byte tidak
berubah. Database protokol tetap versi 14.

## Parameter dan perilaku

| Parameter | adaptive_v2 |
|---|---:|
| Discovery awal / setelah aktif kembali | 1.000 ms + jitter |
| Retry inventory kosong | 4.000, 8.000, 16.000, maksimal 32.000 ms + jitter |
| Pengumuman state baru menunggu DATA | Maksimal 10.000 ms |
| Heartbeat belum stabil | 15.000, 30.000, maksimal 60.000 ms + jitter |
| Heartbeat stabil | 60.000 ms + jitter |
| Freshness dari penerimaan fisik valid | 150.000 ms |
| Jitter STATUS | 0 sampai 1.500 ms |
| Burst STATUS | 500 ms |
| Retry advertising gagal | 1.000 ms + jitter, tanpa menaikkan backoff |
| Cooldown repair | 8.000 ms; interval DATA tidak di-reset jika sudah Imin |

Penerusan DATA baru dianggap berhasil setelah native start sukses. DATA hanya
menggantikan STATUS pengumuman bila semua state inventory lokal sudah tercakup
oleh DATA yang sukses mulai. Ini **bukan** bukti tetangga menerima DATA. Callback
STATUS untuk snapshot lama tidak membatalkan pengumuman inventory yang lebih baru.
STATUS partial tidak membuktikan seluruh inventory tetangga.

Stabil membutuhkan penerusan awal sukses serta HAVE fresh dari semua tetangga
yang benar-benar teramati, bukan dari daftar adjacency yang belum terdengar.
Tanpa pembaruan valid selama 150 detik, HAVE/MISSING menjadi UNKNOWN. Node kosong
terus mencoba, tanpa batas jumlah percobaan. STATUS kosong baru dari tetangga yang
sama dapat memicu repair kembali meskipun isinya sama; deduplikasi frame,
incarnation, sequence, scope dan cooldown tetap diperiksa. STATUS tidak mengambil
slot DATA yang sudah dilindungi scheduler.

## Profil pilot dan artifact

Gunakan `tools/experiment_controller/config.neighbor.adaptive.pilot.example.json`.
Isi ADB serial, lima COM serta **build ID pasangan baru**. Profil memiliki 36 trial
valid: empat metode, tiga skenario, tiga pengulangan; tiga blok masing-masing
memuat semua 12 kombinasi dengan urutan diacak. Pengamatan 180 detik. Attempt
INVALID tetap diarsipkan; FAILED_DELIVERY yang valid tetap dihitung.

Build dengan `powershell -ExecutionPolicy Bypass -File tools/build_neighbor.ps1`.
APK dan firmware baru harus dipasang sebelum pilot. Script build tidak melakukan
install/flash. Gunakan session baru `neighbor-adaptive-pilot-<tanggal-jam>` dan
folder baru `experiment_output/neighbor-adaptive-pilot-<tanggal-jam>/`.
Jangan memakai output/config local smoke lama. Jalankan plan dan readiness dahulu,
lalu smoke; gunakan session/output terpisah untuk run 36 trial. Smoke memiliki
satu attempt per kombinasi (12 trial), bukan dataset utama.

## Pelaporan dan keputusan

Manifest, readiness, fingerprint dan Excel merekam kebijakan serta parameter
efektif. Sheet `STATUS Diagnostics` membedakan discovery, inventory kosong,
perubahan state, heartbeat, native failure, dan `STATUS_COALESCED_WITH_DATA`.
Biaya resmi tetap `DATA_TX + CONTROL_TX`; STATUS tidak disembunyikan. Setup
dilaporkan terpisah sebagai `setup_control_tx` dan `setup_plus_window_tx`.
File JSON/CSV dan semua event mentah dipertahankan.

Profil mencatat baseline diagnostik smoke lama: S0=93, S1=99, S2=94 burst,
**masing-masing hanya satu trial**, bukan tiga pengulangan S0. Sheet
`Adaptive Pilot Review` membandingkan rata-rata setiap skenario tanpa menggabungkan
trial lama dengan dataset baru. Target eksplorasi S0: turun >=50% dari 93
(rata-rata <=46,5 burst). Target bukan kriteria validitas dan bukan bukti statistik.
Bandingkan juga DSR, delay, pemulihan S1/S2 dan total biaya terhadap Trickle biasa.
Heartbeat 60 detik tidak menjamin overhead lebih rendah daripada Trickle biasa.

Pengujian otomatis dan build bukan bukti pilot fisik berhasil. Bekukan pasangan
build dan config sebelum pengambilan data. Hasil buruk tetap dilaporkan.

## Verifikasi implementasi lokal

Pemeriksaan pada 8 Oktober 2026:

| Pemeriksaan | Hasil |
|---|---|
| `dart format --output=none --set-exit-if-changed .` | 100 file, tidak ada perubahan |
| `flutter analyze` | No issues found |
| `flutter test` | 422 test lulus |
| Gradle `test` | Debug 50, profile 46, release 46; tidak ada failure/error |
| PlatformIO native | 28 test lulus |
| Python controller/exporter | 147 test lulus |
| Build firmware ESP32-C3 dan APK debug offline | Berhasil, build ID pasangan `a0ba90c31d93` |
| Pilot perangkat 36 trial | Belum dijalankan; penghematan belum terbukti |

Artifact pasangan tersimpan di
`build/neighbor-a0ba90c31d93-20261008-160539-421/`: `app-debug.apk`,
`firmware.bin`, dan `build_manifest.json`. Build tidak memasang APK atau firmware
ke perangkat. Warning NimBLE/Java/Gradle yang sudah ada tidak menghalangi build.

File implementasi/perluasan pengujian pada perubahan ini:

- `lib/services/neighbor_status_schedule.dart`
- `lib/services/neighbor_status_controller.dart`
- `lib/services/neighbor_runtime.dart`
- `lib/services/ble_advertiser_service.dart`
- `lib/services/ble_relay_service.dart`
- `lib/services/android_experiment_command_service.dart`
- `firmware/esp32c3/include/NeighborStatusSchedule.h`
- `firmware/esp32c3/include/NeighborTransport.h`
- `firmware/esp32c3/src/NeighborTransport.cpp`
- `firmware/esp32c3/src/main.cpp`
- `firmware/esp32c3/test/test_neighbor/test_main.cpp`
- `test/neighbor_status_schedule_test.dart`
- `test/neighbor_adaptive_callback_test.dart`
- `test/neighbor_transport_test.dart`
- `test/android_experiment_command_service_test.dart`
- `android/app/src/testDebug/kotlin/id/ac/usu/resqmesh/ResearchCommandPayloadTest.kt`
  (test helper debug dipindah dari source-set test umum agar Gradle semua varian lulus)
- `tools/experiment_controller/resqmesh_controller/neighbor_experiment.py`
- `tools/experiment_controller/tests/test_neighbor_experiment.py`
- `tools/experiment_controller/tests/test_neighbor_reporting.py`
- `tools/experiment_controller/config.neighbor.adaptive.pilot.example.json`
- `README.md`
- `docs/neighbor_adaptive_status.md`

Perubahan perbaikan command/serial/clock dari pekerjaan sebelumnya tetap
dipertahankan. Tidak ada commit, push, penghapusan dataset atau penggantian config
local pada implementasi ini.
