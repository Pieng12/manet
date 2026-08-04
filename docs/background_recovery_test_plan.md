# Background Recovery Test Plan

Tahap 7 memastikan state relay tidak hanya hidup di memory. Jalankan checklist
ini pada minimal dua perangkat Android BLE setelah build terpasang.

## Persiapan

1. Install build debug atau release.
2. Berikan izin lokasi, Bluetooth scan, Bluetooth advertise, notification, dan
   foreground service.
3. Buat satu SOS aktif.
4. Pastikan ada item aktif di database dan relay queue.
5. Jalankan monitor log:

```bash
adb logcat | findstr /i "ResQMesh MeshBackgroundService NativeBle"
```

## Foreground

1. Buka aplikasi.
2. Kirim SOS.
3. Pastikan scan aktif dan advertising aktif.
4. Perangkat kedua harus menerima payload SOS.

Expected:

- `MeshBackgroundService` berjalan.
- `NativeBleManager` scan active.
- Payload BLE tetap 17 byte.

## Background

1. Tekan Home.
2. Tunggu minimal 2 menit.
3. Kirim payload dari perangkat kedua.

Expected:

- PendingIntent scan menerima payload.
- Service bangun dan mengirim payload ke Dart.
- Queue lama tidak hilang.

## App Removed

1. Swipe aplikasi dari recent apps.
2. Tunggu 1 menit.
3. Kirim payload dari perangkat kedua.

Expected:

- `onTaskRemoved` tidak menghapus database atau relay queue.
- Scan dipulihkan.
- Payload valid tetap bisa membangunkan service.

## Screen Off

1. Matikan layar.
2. Tunggu 5 menit.
3. Kirim payload dari perangkat kedua.

Expected:

- Payload diterima atau tercatat sebagai keterbatasan perangkat/OS.
- Jika gagal, catat model perangkat, versi Android, dan battery optimization
  state.

## Doze

Masukkan perangkat ke idle mode:

```bash
adb shell dumpsys battery unplug
adb shell cmd deviceidle force-idle
```

Kirim payload dari perangkat kedua, lalu keluar dari idle:

```bash
adb shell cmd deviceidle unforce
adb shell dumpsys battery reset
```

Expected:

- Jika payload tidak langsung diterima saat Doze, aplikasi tetap pulih setelah
  keluar dari idle.
- Database dan relay queue tetap utuh.
- Hasil dicatat sebagai batasan OS/perangkat, bukan dianggap selalu aktif.

## Reboot

1. Buat SOS aktif.
2. Reboot perangkat:

```bash
adb reboot
```

3. Setelah boot selesai, tunggu aplikasi/service dipulihkan.

Expected:

- `BootReceiver` memulai `MeshBackgroundService`.
- `recoverPersistedRelayState` berjalan.
- Queue expired dibersihkan.
- SOS aktif yang belum ACK kembali masuk rotasi advertising.

## Battery Optimization

1. Panggil permintaan exemption dari aplikasi.
2. Catat apakah user memberi izin.
3. Verifikasi status:

```bash
adb shell dumpsys deviceidle whitelist | findstr /i "pkmproject"
```

Expected:

- Aplikasi membuka dialog/request Android yang benar.
- Jika user menolak, aplikasi tetap bekerja sebatas izin OS.
