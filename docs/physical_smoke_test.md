# Physical Smoke Test Checklist

Dokumen ini adalah gerbang sebelum batch 90 trial. Unit test dan build tidak
menggantikan bukti perangkat fisik.

## A. Pemeriksaan Perangkat

1. Jalankan `adb devices` dan pastikan Android berstatus `device`.
2. Jalankan `py tools/experiment_controller/run.py discover` dan cocokkan semua
   port COM ESP32 dengan konfigurasi.
3. Flash firmware yang sama ke seluruh ESP32-C3 lalu konfigurasi node melalui
   controller, bukan dengan mengubah source.
4. Aktifkan Bluetooth, izin scan/advertise, notifikasi, location legacy bila
   diperlukan, dan nonaktifkan battery optimization untuk sesi validasi.
5. Jalankan readiness. Semua node harus melaporkan build ID, epoch ID
   `resqmesh-2026-06-01`, epoch valid, mode, role, session, dan clock valid.
6. Jangan mulai trial jika ada mismatch atau queue lama belum kosong.

## B. Interoperabilitas Satu Hop

1. Konfigurasikan Android sebagai SOURCE, satu ESP32 sebagai RELAY, dan satu
   observer/destination.
2. Picu satu logical SOS saja.
3. Cocokkan application payload 17 byte setelah company ID `FF FF` dipisahkan.
4. Verifikasi CRC32 sender, timestamp epoch, signed latitude/longitude, status,
   `hopIn=1`, dan relay `hopOut=2`.
5. Verifikasi burst requested, started, ended, serta receive pada node lain.
6. Advertising requested tanpa callback started bukan TX sukses.

## C. Dua Relay Sejajar

1. Tempatkan R1 dan R2 pada layer yang sama dengan `expectedHopIn=1`.
2. Pastikan keduanya menerima state source yang sama.
3. Pada mode Trickle, buktikan R1 mengirim hop 2 lebih dahulu, R2 mendengar
   state identik, `c` R2 menjadi 1, lalu R2 mencatat `TRICKLE_TX_SUPPRESSED`.
4. Pastikan state/hop/queue R2 tetap ada dan interval berikutnya berlanjut.
5. Ulangi pada Basic. R2 harus mencatat logical duplicate tetapi tidak memakai
   counter suppression dan tetap mengikuti interval tetap plus jitter.
6. Pastikan repeat radio dalam burst yang sama tidak menaikkan `c` dua kali,
   sedangkan burst fisik berikutnya memiliki observation identity berbeda.

## D. Smoke H1, H2, H3

```powershell
py tools/experiment_controller/run.py smoke --config experiment.local.json --output experiment_output
py tools/experiment_controller/run.py merge --input experiment_output/raw --manifest experiment_output/manifest.json --output experiment_output/merged
```

Periksa satu trial per mode dan hop. Validasi hop input/output, destination first
valid receive, sinkronisasi clock E2E, DSR, LDR, dan overhead network-wide.
Batch 15 trial per kondisi baru boleh dimulai setelah keenam trial smoke valid.

## Troubleshooting Windows

- `adb` tidak ditemukan: tambahkan Android SDK `platform-tools` ke `PATH`.
- Android `unauthorized`: cabut/pasang USB, terima dialog RSA, lalu ulangi
  `adb kill-server` dan `adb start-server`.
- COM tidak muncul: pasang driver USB-UART board, gunakan kabel data, periksa
  Device Manager, dan tutup serial monitor lain.
- `Access is denied` pada COM: hanya satu proses boleh membuka port.
- ESP reset saat monitor dibuka: tunggu event `SERVICE_STARTED`, lalu ulangi
  readiness; state packet dipulihkan dari NVS.
- BLE scan kosong: periksa Bluetooth, location legacy, izin Nearby Devices,
  manufacturer ID `0xFFFF`, dan jarak antarperangkat.
- Advertising gagal: pastikan perangkat mendukung peripheral advertising dan
  tidak ada aplikasi lain yang memegang advertiser.
- Android berhenti di background: keluarkan dari battery optimization, periksa
  foreground service notification, Doze, dan log `SCHEDULER_BLOCKED`.
- Epoch invalid: jangan mengubah satu komponen saja. Perbarui Android, firmware,
  controller, dokumentasi, dan test secara serentak.

## Status yang Boleh Dilaporkan

- `CODE VERIFIED`: test source lulus.
- `BUILD VERIFIED`: APK, native Android, dan firmware berhasil dibangun.
- `DEVICE SMOKE TEST NOT RUN`: belum ada bukti perangkat.
- `PHYSICAL MULTI-HOP NOT RUN`: belum ada bukti H1/H2/H3 fisik.
