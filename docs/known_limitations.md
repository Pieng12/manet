# Known Limitations

Dokumen ini mencatat batasan ResQMesh yang diketahui agar hasil penelitian tidak
ditafsirkan melebihi kemampuan implementasi saat ini.

## BLE dan Delivery

- BLE advertising bersifat best-effort dan tidak menjamin semua packet diterima.
- Tidak ada koneksi langsung, handshake, atau retransmission terkonfirmasi antar
  node.
- Packet dapat hilang karena jarak, interferensi, interval scan, interval
  advertising, atau kebijakan vendor Android.
- Payload dibatasi 17 byte sehingga informasi yang dikirim lewat BLE sangat
  ringkas.
- Timestamp compact memakai resolusi detik dan bergantung pada waktu referensi
  penerima.
- Timestamp ACK dan SOS dicanonicalize ke presisi detik; analisis sub-detik
  harus memakai log lokal, bukan payload BLE.
- Karena forwarding bersifat persistent sampai ACK, adaptive backoff wajib
  dipantau pada pengujian baterai multi-jam.
- Fairness ACK/SOS diverifikasi unit test, tetapi dampaknya pada kepadatan radio
  nyata tetap perlu diuji dengan beberapa perangkat fisik.

## Android Background

- Background BLE tidak seragam antar perangkat Android.
- Doze, battery optimization, dan vendor task killer dapat menunda atau
  menghentikan scan/service.
- Android 12+ membatasi start foreground service dari receiver background.
  Native inbox mengurangi risiko packet hilang, tetapi worker recovery tetap
  mengikuti kebijakan OS/vendor.
- Recovery setelah app removed, Doze, atau reboot harus divalidasi pada
  perangkat fisik.
- Recovery queue SOS/ACK bersifat persisten di SQLite, tetapi keberhasilan
  restart service tetap bergantung pada kebijakan background vendor.
- Battery optimization exemption membutuhkan persetujuan user dan tidak
  menjamin service selalu aktif.
- BLE foreground service P5 hanya memakai tipe `connectedDevice`; internet sync
  berjalan melalui WorkManager dan dapat tertunda sampai jaringan tersedia.

## Kompatibilitas Perangkat

- Perangkat yang tidak mendukung BLE advertising tidak dapat menjadi relay aktif.
- Emulator tidak cukup untuk memvalidasi kompatibilitas BLE advertising.
- Compatibility state dari native callback harus dipakai sebagai hasil teknis,
  bukan asumsi.
- Daftar perangkat kompatibel masih perlu diisi dari pengujian fisik.

## Gateway

- Mode gateway tidak aktif secara default.
- Gateway hanya mencoba upload saat `RESQMESH_MODE=gateway`.
- Health check server `GET /health` harus berhasil sebelum upload.
- `connectivity_plus` hanya menunjukkan interface jaringan; reachability server
  tetap ditentukan oleh health check.
- Kontrak ACK server harus mengikuti format terdokumentasi agar client dapat
  memproses ACK secara deterministik.

## Keamanan dan Privasi

- CRC32 hanya identifier ringkas, bukan autentikasi atau enkripsi.
- Payload BLE belum dienkripsi dan dapat dibaca pihak yang mengetahui format
  `RM`.
- Belum ada signature/HMAC pada payload BLE.
- Manufacturer ID `0xFFFF` adalah ID uji/reserved untuk penelitian internal,
  bukan ID produksi resmi.
- Endpoint, token, dan credential rahasia tidak boleh disimpan di repository
  atau payload BLE.

## Scope Non-Tujuan Saat Ini

- Belum mengimplementasikan Bluetooth Mesh resmi.
- Belum mengimplementasikan Bundle Protocol/BPv7.
- Belum mengimplementasikan multi-packet BLE payload.
- Belum menargetkan iOS/web/desktop untuk background BLE.
- Belum mengoptimalkan konsumsi baterai lintas vendor secara menyeluruh.
- Belum ada hasil matrix perangkat fisik Android 8, 10, 12, 13, 14, 15, dan 16
  di repository; klaim stabilitas harus menunggu uji fisik.
