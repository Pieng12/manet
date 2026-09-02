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
- Native `device_address` pada scan BLE hanya dipakai sebagai metadata
  diskriminator observation sementara. Android dapat memakai alamat acak atau
  tidak menyediakan alamat, sehingga identitas node permanen tetap berasal dari
  payload/state ResQMesh.
- Jika alamat BLE tidak tersedia, fallback unknown bersifat bucket waktu burst.
  Dua transmitter fisik berbeda dengan payload identik dalam bucket yang sama
  tidak selalu dapat dibedakan. Repetisi burst yang melintasi boundary bucket
  juga dapat terlihat sebagai observation baru, sehingga hasil fisik tetap perlu
  dikonfirmasi dari log multi-device.
- Klaim `processed_ble_observations` hanya membedakan retry transport internal
  Android dari transmisi radio baru selama retention 24 jam. Retry yang muncul
  setelah retention teoritisnya dapat diproses sebagai observation baru, namun
  periode ini dipilih agar lebih panjang dari retry WorkManager/service normal.
- State klaim `processing` memakai lease 10 menit. Sebelum lease lewat, retry
  native tetap pending agar race direct/inbox tidak menghapus observation yang
  belum selesai; setelah lease lewat, observation dapat diklaim ulang untuk
  recovery crash.
- Durable protocol commit boundary sudah memisahkan replay RX dari side-effect:
  setelah SOS/ACK/duplicate logical commit dan observation menjadi `completed`,
  kegagalan advertiser, WorkManager, gateway scheduling, atau log eksperimen
  tidak membuka ulang observation sebagai `failed_retryable`.
- Schema belum menambahkan fencing token per klaim. Jika processor lama stall
  lebih dari lease lalu hidup lagi setelah processor baru mereclaim observation,
  guard `completed -> failed_retryable` mencegah downgrade state, tetapi audit
  race lintas generation masih mengandalkan lease 10 menit dan operasi protocol
  yang singkat.
- Karena forwarding bersifat persistent sampai ACK, interval Trickle dan
  suppression wajib dipantau pada pengujian baterai multi-jam.
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
