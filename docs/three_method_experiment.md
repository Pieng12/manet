# Eksperimen Tiga Metode: 135 Trial Valid

## Rancangan dan Batas Klaim

Dua faktor diuji: metode (tiga taraf) dan jumlah hop (H1/H2/H3).
Ada 9 kondisi, masing-masing 15 trial valid: 135 trial valid, bukan 135
keberhasilan wajib. Manifest memakai 15 blok; setiap blok memuat 9 kondisi
sekali dengan urutan acak deterministik dari seed. Replacement invalid ditambah
di akhir dan diberi `block=null`, tanpa mengubah urutan blok asli.

Topologi tetap satu Android SOURCE, dua relay paralel lapis 1, dua relay
paralel lapis 2, dan ESP DESTINATION. H1/H2 menonaktifkan lapis yang tidak
digunakan. Hop dibentuk oleh filter hop logis; node dapat berada dalam cakupan
RF yang sama. Ini bukan pembuktian pemisahan radio atau jangkauan fisik.

ESP32-C3 menggantikan Android tambahan sebagai node pengujian karena biaya.
Hasil testbed heterogen ini tidak otomatis berlaku untuk semua jenis Android.
Posisi, orientasi, perangkat, daya pancar per perangkat, scan, radio, payload,
durasi pengamatan, dan kebijakan protokol harus tetap sama antar metode.

## Implementasi dan Parameter

| Identifier | Mesin | Suppression |
| --- | --- | --- |
| `basic_flooding` | Baseline Basic | Tidak memakai Trickle |
| `trickle_no_suppression` | Mesin Trickle bersama | Dinonaktifkan |
| `trickle` | Mesin Trickle bersama | Kirim hanya jika c < k |

Audit kode aktif menemukan Imin=8000 ms, Imax=256000 ms, k=1, burst=2000 ms
di Android dan ESP, tanpa perbedaan parameter. Android merepresentasikan Imax
sebagai 5 penggandaan Imin (8 * 2^5 = 256 detik); ESP memakai durasi absolut.
Kedua varian mempertahankan pemilihan acak t dalam [I/2,I), counter c,
deduplikasi observasi, reset, penggandaan, recovery, queue, dan penghentian.
Hanya predicate suppression berbeda. Kesempatan pertama berada 4 sampai kurang
dari 8 detik sejak interval, termasuk pada SOURCE; tidak ada fast-start tersembunyi.

Basic tidak diubah: burst 2 detik, kemudian tunggu 2 detik + jitter 300-1500 ms.
Start-to-start sekitar 4,3-5,5 detik ditambah overhead API/log/scheduler.
ACK tetap memakai prioritas/fairness queue yang sudah ada. Untuk eksperimen
utama gateway dan ACK dinonaktifkan pada semua metode, bukan dihapus dari
protokol aplikasi. Di luar eksperimen SOS/ACK tetap persisten hingga ACK,
state lebih baru, atau penghapusan administratif. TTL/hop/relay-count legacy
hanya metadata; tidak ditambahkan hard cutoff.

LE Coded extended advertising tetap connectionless, non-connectable,
non-scannable, manufacturer 0xFFFF, application payload 17 byte, interval radio
250 ms. Daya Android dan ESP dapat berbeda, tetapi tidak berubah antar metode
(lihat snapshot readiness). PHY aktual berasal dari ScanResult Android atau
NimBLE RX, bukan konfigurasi yang diminta. `primary_phy=3`, `secondary_phy=3`,
`legacy=false` mendukung penerimaan Coded; coding S2/S8 tetap `unknown`.
Telemetry Android berada di database diagnostik terpisah; kegagalannya tidak
memblokir inbox/worker/transaksi protokol. Tidak mengubah database protokol v14.

## Waktu, Event, dan Metrik

Semua node disiapkan sebelum trigger. Controller menyinkronkan clock per trial.
t0 adalah SOURCE_FIRST_ADVERTISE_STARTED dari keberhasilan API native sumber;
jendela berlangsung tepat 60000 ms setelah t0 menggunakan durasi monotonic
dan timestamp antar node yang sudah dikoreksi. Callback bukan timestamp RF
presisi. Interval/trigger sebelum t0 tetap ada dalam arsip, tetapi bukan bagian
jendela metrik. Latensi gagal-kirim kosong, tidak nol.

Event canonical tetap uppercase agar parser lama tetap dapat membaca arsip:

| Makna | Event |
| --- | --- |
| Awal interval I,t,k,flag suppression | TRICKLE_INTERVAL_STARTED |
| Observasi konsisten, origin CRC, observer, c sebelum/sesudah | TRICKLE_CONSISTENT_HEARD |
| Kesempatan pada t, counter, keputusan | TRICKLE_TX_OPPORTUNITY |
| Diizinkan, alasan C_LT_K / SUPPRESSION_DISABLED | TRICKLE_TX_ALLOWED |
| Ditekan, alasan C_GE_K | TRICKLE_TX_SUPPRESSED |
| Burst aktual sukses / berakhir | ADVERTISE_BURST_STARTED / ADVERTISE_BURST_ENDED |
| Burst dibatalkan karena window/ACK/state/admin | ADVERTISE_BURST_CANCELLED dan reason |

Tidak ada expiry protokol aktif yang baru diaktifkan. Event ACK/state yang
telah ada tetap dicatat terpisah. Cancellation bukan suppression. Counter
konsisten tetap bertambah pada no-suppression dan tidak membuat state baru
atau tampilan pesan berulang. Kesempatan yang diizinkan belum tentu menghasilkan
burst sukses. Zero suppression, termasuk H1, sah.

Empat metrik utama tidak berubah: DSR=SUCCESS/(SUCCESS+FAILED_DELIVERY),
E2E=RX tujuan pertama-t0 untuk pesan/hop yang cocok, LDR=duplicate/(accepted+
duplicate), overhead=total burst SOS sukses network-wide/jumlah trial valid.
Overhead mengukur burst logis, bukan jumlah packet RF fisik. LDR agregat adalah
ratio of sums; `ldr_mean_per_trial` adalah mean of defined trial ratios,
disajikan terpisah. Latensi menampilkan median, quartile/IQR, simpangan baku,
minimum/maksimum dan jumlah delivery, bukan hanya rata-rata.

Suppression rate=kesempatan ditekan/kesempatan Trickle dalam jendela yang sama;
kosong jika penyebut nol. Kesempatan sebelum t0 tidak dimasukkan ke penyebut
window, walaupun burst pertamanya di t0 masuk overhead. Cancellation non-suppression
dan burst aktual ditampilkan terpisah beserta raw event untuk audit.

Workbook menambah Method Parameters, Suppression Summary, RX PHY, Method
Comparisons, dan empat grafik tiga metode. CSV `method_comparisons.csv` memberi
selisih deskriptif per hop untuk Basic vs Trickle (mekanisme keseluruhan) dan
no-suppression vs Trickle (kontribusi suppression). Belum ada analisis inferensial
dalam pipeline ini; tidak membuat p-value. Jika dilakukan kemudian, unitnya
trial, bukan event/node; hormati blok, ties, distribusi dan multiplicity (misalnya
Holm untuk keluarga perbandingan yang ditetapkan sebelumnya). Tidak signifikan
bukan bukti equivalence. Data sintetis hanya fixture test di folder tests/temp.

### Batas klaim dan diagnostik tambahan

Penjelasan workbook memakai bahasa Indonesia, sedangkan nama event/kolom/metode
dan data mentah tetap asli. Trial Order memperlihatkan urutan aktual dari manifest:
smoke sengaja berurutan (`blocked`, block kosong), bukan rancangan batch utama.
Batch utama memakai 15 blok, sembilan kombinasi metode-hop yang diacak per blok.

Telemetry RX membuktikan PHY aktual yang dilaporkan penerima; konfigurasi Coded
bukan bukti tersendiri. Coding S2/S8 belum terverifikasi. Penyaringan hop logis
mendukung evaluasi mekanisme forwarding, bukan klaim jangkauan fisik tiga hop
atau isolasi RF antarlapisan.

Latency Diagnostics menambahkan waktu SOS_CREATED hingga transmisi pertama dan
hingga penerimaan pertama tujuan, dengan identitas pesan/hop serta koreksi jam
yang cocok. E2E utama tetap dihitung sejak SOURCE_FIRST_ADVERTISE_STARTED.
Burst Diagnostics memperlihatkan burst yang lebih pendek dari target tanpa
mengubah event mentah atau hitungan overhead. Alasan penghentian yang tidak
tercatat tetap tidak diketahui; jangan menggantinya dengan dugaan.

Pencatatan alasan OBSERVATION_WINDOW_ENDED memerlukan APK hasil build baru untuk
sesi berikutnya. Jangan mengganti APK/firmware atau menghentikan batch yang
sedang berjalan hanya demi perbaikan laporan ini; dataset lama dapat diekspor
ulang dengan exporter baru tanpa mengubah pengukurannya.

### Callback Trickle terlambat

Deadline t tetap dipilih dalam `[I/2, I)`, tanpa menggeser distribusi random
untuk menghindari batas interval. Callback yang tiba sebelum akhir interval
memutuskan allowed/suppressed memakai c dan flag suppression. Jika kesempatan
belum diputuskan dan interval sudah habis, catat TRICKLE_TX_MISSED/SCHEDULER_LATE
sebelum mengganti interval; jangan mengejar transmisi interval lama. Aturan ini
berlaku sama pada Trickle lengkap dan tanpa suppression, termasuk normalisasi
interval akibat penerimaan paket. Kejadian missed bukan suppression atau burst
dan dilaporkan terpisah, termasuk kejadian sebelum t0.

Android menghitung sisa waktu Timer terhadap deadline absolut dan memasangnya
sebelum diagnostik jadwal ditulis pada jalur Trickle. Basic tidak diubah.
Saat timer bangun, logging wake-up/pemilihan packet tidak ditunggu sebelum keputusan
Trickle. Diagnostik keputusan dan request dikumpulkan dengan waktu kejadian asli,
lalu ditulis setelah jalur keputusan/request native selesai. Waktu sukses native
tetap diambil ketika callback sukses, bukan dari jadwal yang direncanakan.
Kegagalan diagnostik tidak membatalkan advertising yang sudah sukses. Wake-up yang
datang ketika pemilihan sedang sibuk digabung dan diproses kembali jika belum ada
advertising aktif. Tidak menggeser rentang random atau mengirim interval kedaluwarsa.
Pemeriksaan log menolak interval teramati yang telah berakhir tanpa keputusan
atau missed event sebelum interval berikutnya. Satu interval akhir yang masih
berjalan saat pengamatan dihentikan tidak otomatis dianggap missed.

Perbaikan timing ini memerlukan APK dan firmware baru serta smoke sesi baru.
Jangan memakai smoke lama sebagai gate revisi baru atau mencampur dua revisi
dalam satu batch. Pada smoke baru periksa missed_opportunities_total, bukan hanya
SUCCESS: test software tidak menjamin bahwa Android tidak pernah terlambat pada
hardware. Perbaikan tidak mengubah empat metrik, payload BLE, atau data mentah lama.

Pengurangan overhead diagnostik Android ini memerlukan APK baru; firmware yang
sudah mendukung pencatatan missed tidak perlu diubah untuk perbaikan tambahan ini.
Ulangi smoke pada sesi baru dengan APK tersebut sebelum batch utama. Uji simulasi
logging 55 ms pada jadwal 10 ms sebelum akhir interval membuktikan bahwa logging
tidak lagi menunda request native; ini bukan jaminan nol missed pada perangkat
fisik, karena penjadwalan OS dan akses database protokol tetap dapat terlambat.

## Menjalankan dari PowerShell

1. Tinjau perubahan terlebih dahulu. Tidak ada commit/push/install/flash otomatis
   dari implementasi ini. Untuk dataset resmi, bekukan revisi melalui commit
   manual sebelum build sehingga SHA benar-benar mengidentifikasi kode yang diuji.
   Binary lokal verifikasi saat ini memakai SHA HEAD lama dan working tree baru;
   jangan gunakan identitas itu sebagai bukti revisi final yang sudah committed.
2. Sambungkan Android dan kelima ESP. Tutup Serial Monitor/terminal COM lain.
   Izinkan USB debugging, Bluetooth, scan/advertise/location yang dibutuhkan;
   nyalakan layanan relay. Laptop tetap hidup, USB stabil, posisi tidak berubah.
3. Gunakan file lokal baru, bukan konfigurasi/dataset 90 trial lama. File
   `experiment.three_methods.local.json` telah disiapkan dari pemetaan lokal lama,
   tetapi serial/COM wajib dicek ulang setelah perangkat disambungkan kembali.

```powershell
Set-Location D:\PKM\Project\pkmproject
py tools\experiment_controller\run.py discover
$ConfigPath = 'experiment.three_methods.local.json'
$BuildId = (git rev-parse --short=12 HEAD).Trim()
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$Config.session_id = 'resqmesh-three-methods-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$Config.android_build_id = $BuildId
$Config.firmware_build_id = $BuildId
# Periksa/edit serial dan kelima COM dalam $Config sebelum menyimpan.
$Config | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding utf8
$OutputDir = Join-Path $PWD ('experiment_output\' + $Config.session_id)
```

4. Build APK dan firmware dengan SHA sama, lalu install/flash semua perangkat.
   Satu APK mendukung ketiga mode; controller memilih mode per trial, tidak perlu
   build ulang untuk setiap metode. Jangan mengganti binary saat batch berjalan.

```powershell
flutter build apk --debug --dart-define=RESQMESH_MODE=offline --dart-define=RESQMESH_BUILD_ID=$BuildId
if ($LASTEXITCODE -ne 0) { throw 'Build APK gagal' }
$Serial = ($Config.nodes | Where-Object transport -eq 'adb').serial
adb -s $Serial install -r build\app\outputs\flutter-apk\app-debug.apk
if ($LASTEXITCODE -ne 0) { throw 'Install APK gagal' }
adb -s $Serial shell monkey -p id.ac.usu.resqmesh 1
$env:RESQMESH_BUILD_ID = $BuildId
$env:PLATFORMIO_CORE_DIR = 'D:\pio'
$Pio = "$env:USERPROFILE\.platformio\penv\Scripts\platformio.exe"
& $Pio run --project-dir firmware\esp32c3 -e esp32c3
if ($LASTEXITCODE -ne 0) { throw 'Build firmware gagal' }
foreach ($Node in ($Config.nodes | Where-Object transport -eq 'serial')) {
    & $Pio run --project-dir firmware\esp32c3 -e esp32c3 --target upload --upload-port $Node.port
    if ($LASTEXITCODE -ne 0) { throw "Flash gagal: $($Node.node_id)" }
}
```

5. Buat manifest offline, periksa 135 target/15 per kondisi, lalu readiness dan
   smoke 9 kondisi. Folder baru berisi `smoke_run`/`smoke_merged`, terpisah dari
   raw/merged eksperimen utama. Session smoke diberi suffix `-smoke` agar ID
   command/trial tidak bertabrakan dengan main. Fingerprint sama untuk kondisi
   build/radio/topologi; file smoke bukan bagian dataset utama.

```powershell
py tools\experiment_controller\run.py plan --config $ConfigPath --output $OutputDir
py tools\experiment_controller\run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal; jangan mulai trial' }
py tools\experiment_controller\run.py smoke --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Smoke gagal; periksa raw/invalid reasons dahulu' }
```

6. Sebelum batch panjang, buka workbook smoke. Pastikan semua 9 kondisi sukses,
   parameter sama, RX PHY aktual Coded pada penerima aktif, t legal, c>=k pada
   no-suppression tidak menghasilkan suppression, dan reset/quiet terverifikasi.
   Zero suppression saja tidak menggagalkan smoke. Uji kontribusi suppression
   memerlukan paralel relay yang benar-benar saling mendengar, bukan hanya satu ESP.

```powershell
Start-Process (Join-Path $OutputDir 'smoke_merged\resqmesh_analysis.xlsx')
py tools\experiment_controller\run.py run --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Batch belum lengkap; periksa manifest/attempt_summary sebelum resume' }
Start-Process (Join-Path $OutputDir 'merged\resqmesh_analysis.xlsx')
```

Periksa summary 9 kondisi masing-masing `valid=15`; failed delivery tetap
dipertahankan. Invalid tidak dihapus, diberi alasan dan replacement hingga
batas 45 attempt per kondisi. Resume memakai perintah run, config dan output
yang sama; jangan ganti session/seed/build saat resume. Arsip lama tidak
ditimpa atau digabung otomatis. Rencana offline lokal yang sudah dibuat:
`experiment_output/three-methods-plan-20261003/manifest.json` (135 planned,
0 measured); ini bukan hasil eksperimen fisik.

## Catatan untuk Proposal

Penelitian menggunakan desain dua faktor: metode pengendalian retransmisi
(Basic Flooding, Trickle tanpa suppression, Trickle lengkap) dan jumlah hop
logis (1, 2, 3). Masing-masing kombinasi diuji 15 kali valid dalam 15 blok acak
seimbang, sehingga total 135 trial valid. Varian tanpa suppression memakai
penjadwalan Trickle yang sama; hanya pengujian c<k pada kesempatan transmisi
dinonaktifkan. Empat metrik diukur selama 60 detik setelah callback broadcast
sumber pertama yang sukses, dengan koreksi clock antarnode. Dataset pilot dan
arsip rancangan sebelumnya tidak digabung ke eksperimen utama baru.
