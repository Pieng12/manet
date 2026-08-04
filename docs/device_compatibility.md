# Device Compatibility

Dokumen ini adalah registry kompatibilitas perangkat ResQMesh. Isi tabel ini
setiap kali pengujian perangkat fisik dilakukan.

## Kriteria Kompatibel

Perangkat dianggap kompatibel penuh jika memenuhi semua syarat berikut:

- Dapat melakukan BLE scan terhadap manufacturer data ResQMesh.
- Dapat melakukan BLE advertising non-connectable dengan payload 17 byte.
- Dapat menerima payload saat aplikasi foreground.
- Dapat menerima atau pulih setelah background/app removed sesuai kebijakan OS.
- Dapat memulihkan queue setelah service restart atau reboot.
- Izin Bluetooth, lokasi, notification, dan foreground service terpenuhi.

Perangkat yang dapat scan tetapi tidak dapat advertise masih dapat menjadi
receiver/gateway terbatas, tetapi tidak kompatibel sebagai relay aktif.

## Status Uji Saat Ini

Belum ada hasil perangkat fisik yang tercatat di repository ini. Isi tabel di
bawah setelah menjalankan checklist background dan eksperimen.

| Perangkat | Android | Scan BLE | Advertise BLE | Background | Doze | Reboot recovery | Status | Catatan |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Belum diuji | - | - | - | - | - | - | Pending | Tambahkan hasil uji fisik. |

## Template Pencatatan

Gunakan nilai `Pass`, `Partial`, `Fail`, atau `N/A`.

| Field | Isi |
| --- | --- |
| Perangkat | Brand dan model, contoh: Pixel 7. |
| Android | Versi Android dan patch level jika relevan. |
| Scan BLE | Apakah packet 17 byte diterima. |
| Advertise BLE | Apakah callback advertiser sukses. |
| Background | Hasil setelah aplikasi dipindah ke background/app removed. |
| Doze | Hasil saat `adb shell cmd deviceidle force-idle`. |
| Reboot recovery | Apakah service dan queue pulih setelah reboot. |
| Status | `Compatible`, `Receiver only`, `Partial`, atau `Incompatible`. |
| Catatan | Vendor setting, battery optimization, RSSI, jarak, dan bug khusus. |

## Checklist Cepat

1. Install aplikasi pada dua perangkat.
2. Berikan semua permission.
3. Jalankan mode offline pada kedua perangkat.
4. Buat SOS di perangkat A.
5. Pastikan perangkat B menerima packet dan mencatat RSSI.
6. Pastikan perangkat B mengiklankan ulang packet dengan `hopCount+1`.
7. Pindahkan perangkat B ke background dan ulangi pengiriman.
8. Jalankan skenario Doze dan reboot dari
   [`background_recovery_test_plan.md`](background_recovery_test_plan.md).
9. Catat hasil ke tabel kompatibilitas.

## Catatan Android

- Android 12+ membutuhkan `BLUETOOTH_SCAN` dan `BLUETOOTH_ADVERTISE`.
- Android 6-11 umumnya membutuhkan lokasi aktif untuk BLE scan.
- Beberapa vendor membatasi background service secara agresif.
- Battery optimization exemption membantu recovery, tetapi tetap membutuhkan
  persetujuan user.
- Hasil kompatibilitas emulator tidak cukup untuk menyatakan dukungan BLE
  advertising fisik.
