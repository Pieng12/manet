# Uji Jarak Coded Satu Orang

Pilot ini mengukur penerimaan **ESP -> Android**. Laptop dan ESP tetap di posisi
sumber; HP dibawa berjalan ke beberapa titik berhenti yang aman. Bukan eksperimen
90 trial, bukan pengukuran jarak maksimum universal, dan bukan bukti S8.

## Persiapan Sekali Melalui USB

1. Sambungkan HP dan ESP. Tutup Serial Monitor, PlatformIO Monitor, dan terminal
   lama yang masih membuka COM11. Jangan cabut USB ESP selama pengiriman.
2. Buka PowerShell baru pada repository dan periksa perangkat:

   ```powershell
   Set-Location D:\PKM\Project\pkmproject
   adb devices
   [System.IO.Ports.SerialPort]::GetPortNames()
   py -m pip install -r tools\experiment_controller\requirements.txt
   ```

3. Gunakan APK baru, tanpa mengubah firmware ESP Coded yang sudah bekerja:

   ```powershell
   flutter build apk --debug --dart-define=RESQMESH_BUILD_ID=coded-range-pilot-local
   adb -s fbde50b6 install -r build\app\outputs\flutter-apk\app-debug.apk
   adb -s fbde50b6 shell am start -n id.ac.usu.resqmesh/.MainActivity
   ```

4. Aktifkan Bluetooth dan lokasi HP. Buka **Research Monitor -> UJI JARAK**.
   Izinkan lokasi saat aplikasi digunakan. Pertahankan aplikasi di depan layar;
   tidak ada pelacakan lokasi background pada pilot ini.
5. Pastikan trial lama sudah diarsipkan dan difinalisasi sesuai bukti hasilnya.
   Script **menolak** trial Android RUNNING/WINDOW_ENDED yang belum difinalisasi
   atau trial ESP yang masih aktif. Script tidak otomatis mengubah hasil trial
   lama menjadi SUCCESS. Bila ada trial lama, selesaikan melalui Research Monitor
   atau prosedur pengumpulan sesi lamanya terlebih dahulu.

## Mulai Pengiriman

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\range_test.ps1 `
  -Phase Run -Serial fbde50b6 -Port COM11
```

Script menampilkan path `experiment_output\coded-range-<tanggal-jam>`. Catat path
ini untuk pengumpulan nanti. Tidak ada file smoke atau main yang dibersihkan.

Saat script meminta posisi ESP, tandai posisi di tab UJI JARAK dalam 120 detik:

- Ikon lokasi GPS: gunakan saat HP berada dekat ESP dan akurasi <=20 m.
- Ikon edit lokasi: masukkan latitude/longitude sumber yang diketahui.
- Ketuk peta untuk pin sumber saat persiapan. Pin/manual memiliki akurasi **tidak
  terukur**, bukan akurasi GPS nol meter.

Koordinat manual juga dapat diberikan ke script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\range_test.ps1 `
  -Phase Run -Serial fbde50b6 -Port COM11 `
  -SourceLatitude 3.5952 -SourceLongitude 98.6722
```

Ganti koordinat contoh dengan posisi ESP yang sebenarnya. Koordinat pengukuran
disimpan sebagai metadata pilot terpisah, bukan diambil dari lokasi contoh SOS.

**Tunggu `BASELINE PASSED` sebelum mencabut USB HP.** Baseline membutuhkan satu
penerimaan dengan identitas SOS yang cocok dan laporan ScanResult aktual Coded
(primary=3, secondary=3, legacy=false), bukan sekadar konfigurasi radio Coded.
Script hanya memicu satu SOS. Jangan memicu SOS kedua pada sesi yang sama.
Jika baseline gagal, sumber dihentikan oleh cleanup. Arsipkan/finalisasi trial
pilot yang terlanjur dibuat sebagai INVALID sebelum mencoba sesi baru.
Gunakan fase Collect di bawah jika profil pilot sudah terbentuk; bila persiapan
gagal sebelum profil dibuat, arsipkan/finalisasi trial melalui Research Monitor.

## Saat Membawa HP

1. Cabut **USB HP saja**. Biarkan script, laptop, dan ESP menyala; cegah laptop
   sleep. Sesi pengiriman berlangsung 20 menit setelah baseline.
2. Berhenti di titik aman, tekan **Mulai Pengamatan**, lalu diam selama 60 detik.
3. Tunggu **Pengamatan Selesai** sebelum berpindah titik. Jumlah observasi dan
   hasil titik tetap disimpan meskipun GPS atau tile peta tidak tersedia.
4. Ulangi di beberapa titik. Tombol tidak memulai SOS/trial penelitian baru.
5. Jika app masuk background, layar terkunci, scanner gagal, clock berubah,
   atau app restart, titik yang sedang berjalan menjadi INVALID dengan alasan.
   Bukti penerimaan yang sudah tersimpan tidak dihapus.

Lokasi HP yang berusia >5 detik atau akurasi >20 m tidak dipakai untuk jarak.
Jarak adalah estimasi horizontal garis lurus, bukan jarak jalan, beda lantai,
atau jumlah dinding. RSSI tidak dikonversi menjadi meter. Peta dapat dimatikan
melalui ikon tile; jarak dan penyimpanan tidak bergantung pada internet peta.

`Belum ada penerimaan baru` bukan bukti pasti di luar jangkauan. HP hanya
mengetahui penerimaan; kesehatan/penghentian sumber dikonfirmasi dari arsip laptop.
S2/S8 tetap tidak diketahui. Jangan membaca layar saat mengemudi/berkendara.

## Akhir Sesi dan Pengumpulan

Laptop meminta penghentian window dan reset ESP, menunggu quiet period, lalu
memeriksa readiness. Harus tampil **`ESP stop confirmed: True`**. HP tidak dapat
menghentikan atau mengonfirmasi ESP dari jauh tanpa kanal tambahan.

Jika script crash, terminal ditutup, laptop mati, atau penghentian tidak
terkonfirmasi, **matikan ESP sebelum membawa HP mendekat kembali**. Hasil tidak
terverifikasi tetap ditandai; tidak otomatis dianggap sukses.

Setelah kembali, sambungkan HP melalui USB. Tidak perlu membuka COM ESP lagi:

```powershell
$OutputDir = 'D:\PKM\Project\pkmproject\experiment_output\coded-range-YYYYMMDD-HHMMSS'
powershell -NoProfile -ExecutionPolicy Bypass -File tools\range_test.ps1 `
  -Phase Collect -Serial fbde50b6 -OutputDir $OutputDir
Invoke-Item (Join-Path $OutputDir 'resqmesh_range_analysis.xlsx')
```

Ganti path dengan folder yang ditampilkan fase Run. Jangan gunakan folder smoke
atau 90 trial. Collection mencocokkan run ID HP dengan manifest sebelum mengubah
status. Data diarsipkan sebelum reset state trial HP. Jika ekspor gagal, arsip
mentah dipertahankan dan HP tidak di-reset.

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
