# Pengujian Pemulihan MPL 180 Detik

Profil baru tidak mengganti data atau konfigurasi pengujian lama.
Metode: Basic Flooding, Trickle, Trickle-MPL BLE. DATA MPL expiration 3;
Imin 8 detik, Imax 256 detik, k=1 dan seluruh parameter CONTROL tetap.
Timer berhenti tidak menghapus SOS. Payload SOS tetap 17 byte.

## Desain

| Skenario | Gangguan awal | Aktivasi sejak DATA pertama sumber | Window |
| --- | --- | --- | --- |
| S0_STABLE | Tidak ada | Tidak ada | 180 detik |
| S1_BRANCH_DELAYED | D/E TX dan RX OFF | D lalu E ON detik 60 | 180 detik |
| S2_POST_DATA_STOP | E TX dan RX OFF | E ON detik 90 | 180 detik |

D=`esp-r2b`, E=`esp-destination`. Aktivasi berdasarkan event perangkat aktual,
bukan waktu respons command. Jadwal tidak digeser untuk menunggu timer MPL.

ESP-only menggunakan lima ESP: SOURCE=`esp-r1b` dan empat target RELAY.
Graf: S-A, S-C, A-C, A-D, D-E. HP-ESP menggunakan SOURCE=`android-source`
dan lima ESP target RELAY. Graf: HP-R1A, HP-R1B, R1A-R2A, R1B-R2A,
R1A-D, D-E. Graf logis allowlist bukan isolasi radio secara fisik.

Smoke: 9 trial, observasi murni 27 menit. Pilot HP: 27 trial, 81 menit.
Main HP: 135 trial, 6 jam 45 menit. Tambahkan waktu clock sync, konfigurasi,
advertising awal, arsip/reset dan quiet period. Tidak ada retry pada smoke.
FAILED_DELIVERY sah tetap dihitung; hanya INVALID dapat diganti dalam batas
attempt pilot/main. Jangan mengulang hasil sah untuk memperbagus angka.

## Build dan Konfigurasi

Build tidak memasang APK atau flashing perangkat:

```powershell
Set-Location D:\PKM\Project\pkmproject
powershell -ExecutionPolicy Bypass -File tools\build_neighbor.ps1
```

Gunakan pasangan APK/firmware di folder artifact yang dicetak, dengan build ID
yang sama pada konfigurasi. Jangan mengganti build ID sekadar melewati readiness.
Instalasi APK manual: `adb -s fbde50b6 install -r <path-artifact>\app-debug.apk`.
Flashing firmware mengikuti partisi/build perangkat yang sudah digunakan;
tidak dilakukan otomatis oleh controller. Tutup serial monitor sebelum trial.

Contoh konfigurasi di `tools/experiment_controller/`:

- `config.mpl.recovery-180.esp-only.smoke.example.json`
- `config.mpl.recovery-180.hp.smoke.example.json`
- `config.mpl.recovery-180.hp.pilot.example.json`
- `config.mpl.recovery-180.hp.main.example.json`

Empat file lokal baru juga sudah disiapkan pada root repository:

- `experiment.mpl.recovery-180.esp-only.smoke.local.json`
- `experiment.mpl.recovery-180.hp.smoke.local.json`
- `experiment.mpl.recovery-180.hp.pilot.local.json`
- `experiment.mpl.recovery-180.hp.main.local.json`

File lokal memakai build `f3df78c9ce6b`, ADB `fbde50b6` dan mapping COM
sebelumnya. Pasangan artifact ada di
`build/neighbor-f3df78c9ce6b-20261010-035647-243/`.
Periksa perangkat aktual sebelum menggunakan file lokal. Jika melakukan build
baru, gunakan build ID baru yang dicetak script, bukan ID contoh atau ID lama.
Untuk sesi pengambilan berikutnya, gunakan session_id dan folder output baru.

Mapping sebelumnya: R1A COM8, R1B COM9, R2A COM10, D COM11, E COM12.
Periksa ulang dengan `py tools/experiment_controller/run.py discover`
(ESP-only: tambahkan `--serial-only`). Jangan menebak port.
Pertahankan seed 231402098, jadwal dan parameter yang dikunci profil.

## Smoke

Contoh HP-ESP setelah konfigurasi lokal siap:

```powershell
$ConfigPath = (Resolve-Path 'experiment.mpl.recovery-180.hp.smoke.local.json').Path
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$OutputDir = Join-Path (Get-Location) "experiment_output\mpl-hp-180-smoke-$Stamp"
py tools/experiment_controller/run.py plan --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Plan gagal; jangan lanjut' }
py tools/experiment_controller/run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal; jangan lanjut' }
py tools/experiment_controller/run.py smoke --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Smoke belum siap; periksa validasi dan log' }
$SmokeReport = Join-Path $OutputDir 'smoke_report.json'
Start-Process (Join-Path $OutputDir 'smoke_merged\resqmesh_neighbor_analysis.xlsx')
```

Untuk ESP-only, gunakan konfigurasi ESP-only, prefix output
`mpl-esp-only-180-smoke-`, dan workbook `resqmesh_esp_only_analysis.xlsx`.
Sesi konfigurasi juga harus unik untuk setiap pengambilan data baru.

## Pilot dan Main HP

Simpan `$SmokeReport` atau isi dengan path absolut laporan smoke HP terbaru.
Laporan ESP-only tidak dapat dipakai sebagai izin eksperimen HP.
Pilot/main memakai konfigurasi eksperimen yang sama dengan smoke, kecuali ID
sesi, label dan jumlah pengulangan/attempt. Jangan mengubah seed/build/graf.

```powershell
$ConfigPath = (Resolve-Path 'experiment.mpl.recovery-180.hp.pilot.local.json').Path
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$OutputDir = Join-Path (Get-Location) "experiment_output\mpl-hp-180-pilot-$Stamp"
py tools/experiment_controller/run.py plan --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Plan gagal' }
py tools/experiment_controller/run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal' }
py tools/experiment_controller/run.py run --config $ConfigPath --output $OutputDir --smoke-report $SmokeReport
if ($LASTEXITCODE -ne 0) { throw 'Batch belum lengkap; periksa manifest/log' }
Start-Process (Join-Path $OutputDir 'merged\resqmesh_neighbor_analysis.xlsx')
```

Setelah pilot menunjukkan core checks PASS, CONTROL masuk Android, dan bukti
repair S2 MPL, ulang perintah menggunakan konfigurasi `.hp.main.local.json`
serta prefix output `mpl-hp-180-main-`. Jangan gabungkan pilot ke dataset main.
Jaga laptop/HP aktif, USB stabil, izin BLE tersedia dan tidur otomatis dimatikan.

## Membaca Hasil

Empat metrik tetap DSR, E2E, LDR dan overhead DATA+CONTROL seluruh node.
DSR denominator empat target pada ESP-only, lima pada HP-ESP. Setup terpisah;
burst bukan jumlah paket RF atau konsumsi energi.

Metrik kelima pendukung: waktu pemulihan dari ON ke RX fisik pertama, memakai
jam monoton dan boot epoch target yang sama. S1 melaporkan D/E terpisah,
S2 E saja, S0 tidak berlaku. Delay gagal kosong, bukan nol/180 detik. Baca
jumlah target layak/menerima/belum menerima dan jumlah waktu terdefinisi.
Statistik per target dan rata-rata per trial dibedakan. Sisa window memakai
batas wall clock terkoreksi dan bukan pengganti delay monoton.

Excel berisi Desain Pengujian, Pemulihan Node, Statistik Pemulihan, Validasi,
grafik pemulihan beserta jumlah penerima, kurva delivery/overhead kumulatif,
tabel teknis dan All Events. JSON/CSV dan log mentah tetap disimpan.

Smoke siap tidak mensyaratkan semua pembanding sukses delivery, tetapi wajib
hasil sah, log lengkap, core checks PASS, bukti repair S2 MPL PASS dan CONTROL
masuk Android untuk profil HP. Batch lengkap, delivery dan bukti mekanisme
merupakan status berbeda. INCONCLUSIVE bukan PASS.

Nominal stop DATA 56 detik hanya tanpa reset dan sejak timer tiap node mulai.
Jika D belum stop atau restart sebelum E ON, klaim S2 INCONCLUSIVE; jangan
ubah jadwal tengah batch. Catat hasil pilot dan revisi profil terpisah bila
desain pasca-stop belum terwujud. Jangan menganggap seluruh penghematan berasal
dari CONTROL, karena expiration DATA juga memendekkan fase awal.

Jika USB terputus/Ctrl+C/cleanup gagal, arsip parsial tetap disimpan. Jangan
lanjut sebelum advertising dipastikan berhenti; matikan ESP jika status tidak
dapat dikonfirmasi. Jangan memakai hasil partial sebagai batch lengkap.
