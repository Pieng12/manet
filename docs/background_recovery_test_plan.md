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
- Service memakai foreground service type `connectedDevice`, bukan `dataSync`.
- `recoverPersistedRelayState` berjalan.
- Queue persisten dipulihkan tanpa menghapus SOS aktif karena lifetime/max hop.
- SOS aktif dan ACK anti-message yang belum terminal kembali masuk rotasi
  advertising.
- Jika OS menolak start foreground service, `NativeBleInboxWorker` menjadwalkan
  recovery dan payload native inbox tetap pending.

## Native Inbox

1. Jalankan perangkat penerima, lalu hentikan aplikasi sebelum Flutter siap.
2. Kirim payload BLE valid dari perangkat kedua.
3. Buka aplikasi/service kembali.

Expected:

- `BleWakeUpReceiver` menyimpan payload sebelum mencoba service.
- `getPendingBleInbox` mengembalikan item pending.
- Dart memproses payload dan memanggil `acknowledgeBleInboxItem`.
- Jika processing gagal, `failBleInboxItem` menaikkan `attempt_count` dan item
  tetap dapat di-retry.
- Duplicate payload dengan sender/timestamp/status sama tidak membuat record
  pending identik tanpa batas.

## Queue Wake Backoff

1. Buat beberapa SOS/ACK sampai scheduler masuk backoff.
2. Pastikan native advertiser boleh inactive saat menunggu.
3. Tunggu melewati `earliestNextEligibleAt`.

Expected:

- Log mencatat `WAITING_NEXT_ELIGIBLE` dan `QUEUE_WAKE_SCHEDULED`.
- Saat waktunya tiba, log mencatat `QUEUE_WAKE_TRIGGERED`.
- Service tidak berhenti hanya karena advertiser inactive selama relay mode atau
  queue pending masih ada.

## Battery Optimization

1. Panggil permintaan exemption dari aplikasi.
2. Catat apakah user memberi izin.
3. Verifikasi status:

```bash
adb shell dumpsys deviceidle whitelist | findstr /i "id.ac.usu.resqmesh"
```

Expected:

- Aplikasi membuka dialog/request Android yang benar.
- Jika user menolak, aplikasi tetap bekerja sebatas izin OS.
