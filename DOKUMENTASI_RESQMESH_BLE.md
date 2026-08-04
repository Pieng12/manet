# Dokumentasi ResQMesh BLE-Only Connectionless

## 1. Ringkasan Project

**ResQMesh** adalah aplikasi mobile berbasis Flutter yang dirancang untuk mengirim dan menyebarkan pesan SOS pada situasi darurat atau bencana, terutama ketika jaringan seluler dan internet tidak tersedia.

Versi terbaru project ini menggunakan pendekatan **BLE-only connectionless**, yaitu komunikasi antar perangkat dilakukan dengan **Bluetooth Low Energy Advertising** dan **BLE Scanning** tanpa pairing, tanpa koneksi langsung, dan tanpa Nearby Connections atau Wi-Fi Aware.

Alur utama:

1. Pengguna membuka aplikasi dan menekan tombol **SEND SOS**.
2. Aplikasi mengambil lokasi pengguna.
3. Pesan SOS disimpan ke database lokal SQLite.
4. Payload SOS 17 byte disisipkan ke BLE manufacturer data.
5. Perangkat mulai melakukan BLE advertising.
6. Perangkat lain yang memiliki aplikasi melakukan BLE scan di background.
7. Jika perangkat lain membaca payload valid dengan header `RM`, pesan disimpan ke database lokal perangkat tersebut.
8. Perangkat penerima otomatis melakukan relay dengan mengiklankan ulang payload SOS.
9. Jika salah satu perangkat memiliki internet, perangkat tersebut menjadi **opportunistic gateway** dan mengirim pesan ke server.
10. Jika server menerima pesan, aplikasi memproses ACK berdasarkan timestamp.
11. ACK disebarkan kembali melalui BLE.
12. Perangkat yang menerima ACK menghentikan broadcast hanya jika ACK valid dan tidak lebih lama dari pesan lokal.

Tujuan sistem:

- Mengirim pesan darurat tanpa internet.
- Menyebarkan pesan ke perangkat sekitar secara connectionless.
- Mengurangi kebutuhan interaksi manual setelah aktivasi.
- Mempertahankan data di penyimpanan lokal.
- Mengirim data ke server ketika ada perangkat yang memiliki internet.
- Menghentikan broadcast pesan lama menggunakan ACK berbasis timestamp.

## 2. Topik Skripsi Yang Cocok


Judul yang direkomendasikan:

**Implementasi dan Evaluasi Sistem Pengiriman SOS Connectionless Berbasis Bluetooth Low Energy Advertising pada Aplikasi Android**

Alternatif judul:

1. **Rancang Bangun Sistem Relay Pesan Darurat Tanpa Internet Menggunakan BLE Advertising pada Perangkat Android**
2. **Evaluasi Penggunaan Bluetooth Low Energy Advertising untuk Komunikasi SOS Offline pada Kondisi Bencana**
3. **Pengembangan Aplikasi SOS Offline-First Berbasis BLE Beacon dengan Mekanisme Store-and-Forward**

Fokus penelitian:

- BLE advertising sebagai media komunikasi connectionless.
- Mekanisme relay otomatis antar perangkat.
- Opportunistic gateway saat salah satu perangkat memiliki internet.
- Validasi ACK berdasarkan timestamp.
- Evaluasi jarak, waktu penerimaan, success rate, dan konsumsi daya.

## 3. Metode Penelitian

Metode yang paling sesuai:

**Research and Development (R&D) dengan pendekatan prototyping dan pengujian eksperimental.**

Alternatif metode akademik:

**Design Science Research Methodology (DSRM).**

Tahapan penelitian:

1. **Identifikasi masalah**
   - Komunikasi darurat sering gagal ketika jaringan seluler atau internet tidak tersedia.
   - Perangkat korban tetap membutuhkan cara untuk menyebarkan lokasi dan status SOS.

2. **Analisis kebutuhan**
   - Sistem harus dapat berjalan tanpa internet.
   - Sistem harus connectionless.
   - Sistem harus hemat daya.
   - Sistem harus dapat menyimpan data lokal.
   - Sistem harus dapat mengirim data ke server saat internet tersedia.
   - Sistem harus mencegah broadcast pesan lama dengan ACK.

3. **Perancangan sistem**
   - Arsitektur BLE-only.
   - Payload 17 byte.
   - Database lokal.
   - Background service Android.
   - WorkManager untuk retry sinkronisasi.
   - ACK timestamp untuk menghentikan broadcast.

4. **Implementasi**
   - Flutter untuk aplikasi.
   - Kotlin native Android untuk BLE advertising, BLE scan, receiver, dan background service.
   - SQLite untuk penyimpanan lokal.
   - HTTP API untuk sinkronisasi server.

5. **Pengujian**
   - Unit test protokol BLE.
   - Build test Android.
   - Uji perangkat fisik minimal 2 HP.
   - Uji offline, online, relay, ACK, dan timestamp.

6. **Evaluasi**
   - Success rate penerimaan SOS.
   - Latency penerimaan.
   - Jarak penerimaan.
   - Keberhasilan relay.
   - Keberhasilan gateway ke server.
   - Keberhasilan ACK menghentikan broadcast lama.
   - Ketahanan background service.

## 4. Teknologi Yang Digunakan

### 4.1 Platform

- **Flutter**
  - Digunakan untuk UI, state aplikasi, routing, database access, dan service orchestration.

- **Dart**
  - Bahasa utama untuk logika aplikasi Flutter.

- **Android Native Kotlin**
  - Digunakan untuk fitur BLE yang perlu akses native:
    - BLE advertising.
    - BLE scanning dengan PendingIntent.
    - BroadcastReceiver.
    - Foreground background service.
    - MethodChannel Flutter-Native.

- **SQLite**
  - Digunakan sebagai penyimpanan lokal SOS.

- **HTTP REST API**
  - Digunakan untuk opportunistic gateway ketika internet tersedia.

### 4.2 Library Flutter

Daftar library dari `pubspec.yaml`:

| Library | Fungsi |
| --- | --- |
| `flutter` | Framework utama aplikasi. |
| `cupertino_icons` | Ikon gaya iOS, dependency standar Flutter. |
| `http` | Komunikasi dengan backend API. |
| `geolocator` | Mengambil lokasi pengguna saat SOS dibuat. |
| `sqflite` | Database SQLite lokal. |
| `path` | Membantu pembuatan path database. |
| `uuid` | Membuat ID unik untuk pesan SOS dan device. |
| `encrypt` | Dependency kriptografi, belum menjadi mekanisme inti BLE saat ini. |
| `connectivity_plus` | Mengecek status koneksi internet. |
| `shared_preferences` | Menyimpan device ID, flag pending sync, dan pending ACK BLE. |
| `permission_handler` | Meminta izin Bluetooth, lokasi, notifikasi, dan battery optimization. |
| `flutter_reactive_ble` | Mengecek status BLE/Bluetooth pada layer Flutter. |
| `functional_data` | Dependency utilitas, tidak menjadi inti alur BLE-only. |
| `logging` | Dependency logging, saat ini sebagian kode masih memakai `print`. |
| `intl` | Format tanggal/waktu pada UI. |
| `battery_plus` | Menyesuaikan interval sync berdasarkan level baterai. |
| `flutter_ble_peripheral` | Fallback BLE advertising jika native Android tidak tersedia. |
| `flutter_map` | Menampilkan lokasi SOS di peta. |
| `latlong2` | Tipe koordinat untuk `flutter_map`. |
| `path_provider` | Akses direktori lokal aplikasi. |
| `app_settings` | Membantu membuka pengaturan aplikasi/perangkat. |
| `workmanager` | Menjalankan retry sinkronisasi saat internet tersedia. |
| `flutter_map_tile_caching` | Cache tile peta untuk kebutuhan offline map. |
| `flutter_lints` | Aturan lint untuk menjaga kualitas kode. |
| `flutter_test` | Unit test dan widget test Flutter. |

Library yang sengaja dihapus dari desain terbaru:

- `nearby_connections`
- Wi-Fi Aware native manager
- service P2P berbasis koneksi langsung

## 5. Struktur Project

Struktur folder utama:

```text
pkmproject/
  android/
    app/src/main/
      AndroidManifest.xml
      kotlin/com/example/pkmproject/
        MainActivity.kt
        MeshBackgroundService.kt
        NativeBleAdvertiser.kt
        NativeBleManager.kt
        BleWakeUpReceiver.kt
        BootReceiver.kt
        ConnectivityReceiver.kt
  ios/
  linux/
  macos/
  web/
  windows/
  lib/
    main.dart
    sync_service.dart
    database_schema.dart
    models/
      sos_message.dart
    screen/
      splash_screen.dart
      onboarding_screen.dart
      permission_screen.dart
      home_screen.dart
      mesh_monitor_screen.dart
    services/
      api_service.dart
      background_service_manager.dart
      ble_advertiser_service.dart
      ble_protocol.dart
      ble_relay_service.dart
      database_helper.dart
      database_service.dart
      demo_seed_service.dart
      location_service.dart
      native_bridge_service.dart
      workmanager_service.dart
    utils/
      hash_utils.dart
      navigator_key.dart
    widgets/
      improved_dialogs.dart
      logs_tab.dart
      map_tab.dart
      message_filter_bar.dart
      messages_tab.dart
      service_status_bar.dart
      sos_map_view.dart
      sos_message_card.dart
      status_indicator.dart
  test/
    ble_protocol_test.dart
  pubspec.yaml
  README.md
  DOKUMENTASI_RESQMESH_BLE.md
```

Catatan:

- Folder `ios`, `linux`, `macos`, `web`, dan `windows` masih ada karena project Flutter bersifat multi-platform.
- Fitur BLE background difokuskan pada Android.
- Android native Kotlin adalah bagian penting karena BLE background dan PendingIntent tidak cukup ditangani oleh Dart murni.

## 6. Modul Utama Dan Fungsinya

### 6.1 `lib/main.dart`

Fungsi:

- Entry point aplikasi.
- Inisialisasi Flutter binding.
- Inisialisasi database.
- Inisialisasi device identity.
- Inisialisasi offline map cache.
- Menjalankan cleanup duplicate data.
- Inisialisasi WorkManager.
- Menjalankan listener sinkronisasi internet.
- Menjalankan background service.
- Menjalankan BLE relay service.
- Mendefinisikan route aplikasi.
- Menyediakan entry point background isolate: `backgroundServiceMain`.

Background isolate menerima event:

- `bleWakeUpTriggered`
- `blePayloadReceived`
- `connectivityChanged`

Jika menerima `blePayloadReceived`, payload base64 akan diteruskan ke `BleRelayService`.

### 6.2 `lib/services/ble_protocol.dart`

Fungsi:

- Sumber kebenaran format payload BLE.
- Pack SOS menjadi 17 byte.
- Pack ACK menjadi 17 byte.
- Unpack payload BLE menjadi `BlePacket`.
- Validasi header `RM`.
- Membedakan packet SOS dan packet ACK.

Konsep:

- Header: `RM`
- Panjang payload: 17 byte
- Timestamp compact: 3 byte
- Koordinat latitude: 3 byte
- Koordinat longitude: 3 byte
- Status: 1 byte
- Flags: 1 byte

### 6.3 `lib/services/ble_relay_service.dart`

Fungsi:

- Service inti untuk BLE-only relay.
- Menjalankan BLE scan.
- Menyimpan SOS lokal.
- Mengiklankan SOS.
- Menerima payload BLE.
- Decode payload SOS atau ACK.
- Relay otomatis payload SOS yang valid.
- Proses ACK timestamp.
- Mencoba gateway sync ketika internet tersedia.

Alur saat menerima SOS:

1. Decode payload BLE.
2. Validasi header `RM`.
3. Pastikan packet adalah SOS.
4. Buat `SOSMessage`.
5. Cek apakah pesan lebih baru dari database lokal.
6. Jika lebih baru, simpan ke SQLite.
7. Advertise ulang pesan tersebut.
8. Register WorkManager sync.
9. Jika ada internet, jalankan `SyncService.initiateFullSync()`.

Alur saat menerima ACK:

1. Decode packet ACK.
2. Cari pesan lokal dengan `senderCrc` yang sama.
3. Bandingkan timestamp lokal dengan timestamp ACK.
4. Jika `local.updatedAt <= ackTimestamp`, pesan dianggap sudah diterima server dan broadcast dihentikan.
5. Jika lokal lebih baru, ACK diabaikan dan pesan terbaru tetap diiklankan.

### 6.4 `lib/services/ble_advertiser_service.dart`

Fungsi:

- Mengiklankan payload SOS via BLE.
- Mengiklankan payload ACK via BLE.
- Menyimpan pending ACK jika native channel belum siap.
- Mengembalikan iklan BLE ke pesan SOS terbaru setelah ACK selesai diiklankan.
- Menjalankan watchdog untuk menjaga native BLE advertising tetap aktif.

Jenis iklan:

- SOS advertising.
- ACK advertising.

Jika tidak ada pesan unsynced dan tidak ada ACK pending:

- Advertising dihentikan.

### 6.5 `lib/sync_service.dart`

Fungsi:

- Menyimpan dan memuat device ID.
- Mengecek koneksi internet.
- Mengirim latest state lokal ke server.
- Mengunduh data terbaru dari server.
- Memproses ACK dari server.
- Mengatur adaptive sync berdasarkan koneksi dan baterai.
- Menjalankan sync listener saat koneksi berubah.

Prinsip:

- Yang dikirim ke server adalah **latest state per device/sender CRC**.
- ACK lama tidak boleh menghentikan pesan yang lebih baru.
- ACK valid disebarkan lagi melalui BLE.

### 6.6 `lib/services/workmanager_service.dart`

Fungsi:

- Mendaftarkan one-off task saat ada pesan yang belum terkirim.
- Menjalankan sync ketika internet tersedia.
- Menyimpan flag `pending_sync`.
- Menghapus flag jika sync berhasil.

Kondisi penggunaan:

- Saat SOS dibuat offline.
- Saat perangkat menerima SOS dari BLE.
- Saat pembatalan SOS perlu dikirim ke server.

### 6.7 `lib/services/database_helper.dart`

Fungsi:

- Membuat database lokal.
- Insert/update/delete SOS.
- Mengambil pesan unsynced.
- Menentukan apakah pesan masuk lebih baru.
- Mengganti pesan lama dengan pesan terbaru berdasarkan sender.
- Membersihkan duplicate lama.
- Broadcast perubahan database ke UI melalui stream.

### 6.8 `lib/models/sos_message.dart`

Model utama pesan SOS.

Field penting:

| Field | Fungsi |
| --- | --- |
| `id` | ID unik pesan lokal. |
| `senderId` | ID perangkat pengirim. |
| `senderCrc` | ID ringkas 4 byte untuk payload BLE. |
| `fromServer` | Penanda data berasal dari server. |
| `senderName` | Nama pengirim jika tersedia. |
| `content` | Isi pesan. |
| `latitude` | Lokasi latitude. |
| `longitude` | Lokasi longitude. |
| `status` | Status SOS: `cancelled`, `active`, `resolved`. |
| `createdAt` | Waktu dibuat. |
| `updatedAt` | Waktu update terakhir. |
| `isSynced` | Status sinkronisasi ke server. |

### 6.9 Android Native Kotlin

#### `MainActivity.kt`

Fungsi:

- Menghubungkan Flutter dan Android native melalui MethodChannel.
- Menangani perintah:
  - Start/stop background service.
  - Request battery optimization.
  - Start/stop BLE scan.
  - Start/stop native BLE advertising.
  - Cek status native BLE advertising.
- Mengelola receiver Bluetooth state saat activity foreground.

#### `NativeBleAdvertiser.kt`

Fungsi:

- Mengaktifkan BLE advertising native Android.
- Menyisipkan payload 17 byte ke manufacturer data.
- Menggunakan service UUID khusus ResQMesh.
- Menyimpan payload terakhir agar dapat direstart oleh watchdog.

#### `NativeBleManager.kt`

Fungsi:

- Mengaktifkan BLE scan native Android.
- Menggunakan ScanFilter manufacturer data.
- Menggunakan PendingIntent agar receiver bisa aktif saat background.
- Mengarahkan hasil scan ke `BleWakeUpReceiver`.

#### `BleWakeUpReceiver.kt`

Fungsi:

- Menerima hasil BLE scan.
- Mencari signature `RM`.
- Mengambil 17 byte payload.
- Melakukan deduplikasi native sederhana.
- Menyalakan `MeshBackgroundService`.
- Mengirim payload base64 ke Flutter background isolate.

#### `MeshBackgroundService.kt`

Nama class masih `MeshBackgroundService` untuk kompatibilitas manifest dan kode lama, tetapi fungsinya sekarang adalah **BLE background service**.

Fungsi:

- Menjalankan foreground service.
- Menyalakan Flutter headless engine.
- Menjaga BLE scan tetap aktif.
- Menjaga BLE advertising tetap aktif jika ada payload.
- Menerima event BLE wake-up.
- Menerima event perubahan koneksi.
- Menghubungkan native event ke `backgroundServiceMain`.

#### `ConnectivityReceiver.kt`

Fungsi:

- Mendeteksi perubahan koneksi internet.
- Jika internet tersedia, memicu sync di Flutter background engine.

#### `BootReceiver.kt`

Fungsi:

- Menyalakan background service setelah perangkat boot.
- Mendukung zero touch setelah perangkat menyala kembali, selama permission sudah diberikan.

## 7. Protokol BLE 17 Byte

Payload BLE selalu 17 byte.

Header:

```text
Byte 0: 0x52 ('R')
Byte 1: 0x4D ('M')
```

### 7.1 Format SOS Packet

```text
Byte 0-1   : Header "RM"
Byte 2-5   : senderCrc, uint32 big endian
Byte 6-8   : updatedAtDelta, 24-bit timestamp compact
Byte 9-11  : latitude compressed, 24-bit
Byte 12-14 : longitude compressed, 24-bit
Byte 15    : status enum index
Byte 16    : flags
```

Status:

```text
0 = cancelled
1 = active
2 = resolved
```

Flags:

```text
bit 7 = ACK flag
bit 6 = fromServer flag
bit 0-5 = hop count
```

Untuk SOS:

```text
ACK flag = 0
```

### 7.2 Format ACK Packet

```text
Byte 0-1   : Header "RM"
Byte 2-5   : senderCrc yang di-ACK
Byte 6-8   : ackTimestampDelta, 24-bit timestamp compact
Byte 9-14  : reserved, diisi 0
Byte 15    : ack status
Byte 16    : flags dengan ACK bit aktif
```

Untuk ACK:

```text
ACK flag = 1
```

Aturan ACK:

```text
ACK valid jika local.senderCrc == ack.senderCrc
dan local.updatedAt <= ackTimestamp
```

Karena timestamp di BLE payload dikompresi sampai resolusi detik, perbandingan ACK dilakukan pada resolusi detik.

### 7.3 Alasan Payload 17 Byte

BLE legacy advertising memiliki batas ukuran yang ketat. Payload dibuat ringkas agar:

- Muat di manufacturer data.
- Tidak perlu membuat koneksi BLE.
- Bisa diterima banyak perangkat secara broadcast.
- Hemat daya dibanding transfer data besar.
- Cocok untuk pesan darurat yang hanya membutuhkan ID, lokasi, status, dan waktu.

## 8. Alur Sistem

### 8.1 Alur Pengiriman SOS

```text
User tekan SEND SOS
  -> LocationService mengambil lokasi
  -> SOSMessage dibuat
  -> senderCrc dihitung dari device ID
  -> DatabaseHelper menyimpan pesan
  -> BleRelayService mengaktifkan BLE scan
  -> BleAdvertiserService mengiklankan SOS 17 byte
  -> WorkManager task didaftarkan
  -> SyncService mencoba sync jika internet tersedia
```

### 8.2 Alur Penerimaan SOS

```text
NativeBleManager scan BLE
  -> BleWakeUpReceiver menerima manufacturer data
  -> Receiver mencari header "RM"
  -> Payload 17 byte dikirim ke MeshBackgroundService
  -> backgroundServiceMain menerima blePayloadReceived
  -> BleRelayService decode payload
  -> DatabaseHelper cek timestamp
  -> Jika lebih baru, simpan ke SQLite
  -> Perangkat otomatis relay dengan BLE advertising
  -> Jika internet tersedia, perangkat mencoba upload ke server
```

### 8.3 Alur Opportunistic Gateway

```text
Perangkat menerima/menyimpan SOS
  -> Cek connectivity
  -> Jika online, SyncService upload latest state ke server
  -> Server mengirim ACK
  -> SyncService validasi ACK
  -> ACK disimpan/disebarkan melalui BLE
```

### 8.4 Alur ACK

```text
Server ACK diterima
  -> Ambil senderCrc dan timestamp ACK
  -> Cari pesan lokal yang cocok
  -> Jika pesan lokal lebih lama/sama, set isSynced = 1
  -> Stop advertising pesan tersebut
  -> Broadcast ACK via BLE
  -> Setelah ACK selesai diiklankan, kembali advertise SOS terbaru jika masih ada
```

Jika ACK lebih lama:

```text
ACK timestamp < local updatedAt
  -> ACK diabaikan
  -> Pesan lokal terbaru tetap diiklankan
  -> Pesan terbaru tetap akan dikirim ke server saat online
```

## 9. Database Lokal

Database menggunakan SQLite melalui `sqflite`.

Tabel utama:

```sql
CREATE TABLE sos_messages (
  id TEXT PRIMARY KEY,
  sender_id TEXT,
  sender_name TEXT NULL,
  content TEXT,
  latitude REAL,
  longitude REAL,
  status INTEGER,
  created_at INTEGER,
  updated_at INTEGER,
  is_synced INTEGER DEFAULT 0,
  sender_crc INTEGER NULL,
  from_server INTEGER DEFAULT 0
);
```

Fungsi kolom:

| Kolom | Fungsi |
| --- | --- |
| `id` | Primary key pesan. |
| `sender_id` | ID perangkat pengirim. |
| `sender_name` | Nama pengirim opsional. |
| `content` | Isi pesan SOS. |
| `latitude` | Latitude lokasi. |
| `longitude` | Longitude lokasi. |
| `status` | Status pesan dalam bentuk integer enum. |
| `created_at` | Waktu pembuatan pesan. |
| `updated_at` | Waktu update terakhir. |
| `is_synced` | 0 belum sync, 1 sudah sync. |
| `sender_crc` | ID ringkas untuk BLE payload. |
| `from_server` | Penanda data berasal dari server. |

Strategi data:

- Data lokal selalu disimpan lebih dulu sebelum broadcast.
- Pesan dari sender yang sama diganti jika timestamp lebih baru.
- Pesan lama tidak menggantikan pesan baru.
- ACK tidak mengubah `updated_at`.

## 10. API Dan Sinkronisasi Server

Base URL backend:

```text
https://resqmesh-backend-production.up.railway.app/api
```

Endpoint yang digunakan:

| Endpoint | Method | Fungsi |
| --- | --- | --- |
| `/sos` | POST | Kirim satu pesan SOS langsung. |
| `/sync/upload` | POST | Upload daftar latest state lokal. |
| `/sync/download?since=...` | GET | Download data terbaru sejak timestamp terakhir. |

Payload API dari `SOSMessage.toApiJson()` berisi:

- `local_message_id`
- `sender_device_id`
- `sender_name`
- `content`
- `latitude`
- `longitude`
- `status`
- `occurred_at`
- `device_id`
- `sender_crc`
- `from_server`
- `battery_level`
- `timestamp`

ACK server yang didukung:

- `ack_data`
- `processed_ids`
- `ack_timestamp`
- `sender_crc`
- `sender_device_id`
- `local_message_id`
- `occurred_at`
- `updated_at`
- `timestamp`

## 11. Zero Touch After Activation

Makna zero touch dalam project ini:

1. Pengguna tetap perlu membuka aplikasi dan memberikan permission awal.
2. Pengguna korban perlu menekan tombol SOS untuk aktivasi pertama.
3. Setelah SOS aktif, perangkat otomatis:
   - Scan BLE.
   - Advertise payload SOS.
   - Menerima payload dari perangkat lain.
   - Menyimpan payload valid.
   - Relay payload valid.
   - Mencoba sync jika internet tersedia.
   - Menyebarkan ACK jika ada.
4. Perangkat relawan yang sudah pernah membuka aplikasi dan memberi izin dapat menjadi node relay tanpa menekan tombol SOS.

Batasan Android:

- Background BLE bergantung pada izin Bluetooth, lokasi, notifikasi, dan kebijakan battery optimization.
- Beberapa vendor Android agresif membatasi background service.
- Karena itu aplikasi meminta ignore battery optimization.

## 12. Permission Android

Permission yang digunakan:

| Permission | Fungsi |
| --- | --- |
| `INTERNET` | Mengirim data ke backend. |
| `ACCESS_NETWORK_STATE` | Mengecek kondisi koneksi. |
| `ACCESS_FINE_LOCATION` | Dibutuhkan BLE scan di banyak perangkat Android dan untuk lokasi SOS. |
| `BLUETOOTH` | Dukungan Bluetooth lama. |
| `BLUETOOTH_ADMIN` | Dukungan Bluetooth lama. |
| `BLUETOOTH_SCAN` | Scan BLE pada Android 12+. |
| `BLUETOOTH_ADVERTISE` | Advertising BLE pada Android 12+. |
| `BLUETOOTH_CONNECT` | Operasi Bluetooth tertentu pada Android 12+. |
| `FOREGROUND_SERVICE` | Menjalankan service background. |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Foreground service untuk perangkat terkoneksi/BLE. |
| `FOREGROUND_SERVICE_DATA_SYNC` | Foreground service untuk sync data. |
| `FOREGROUND_SERVICE_LOCATION` | Foreground service terkait lokasi. |
| `WAKE_LOCK` | Membantu service tetap aktif. |
| `POST_NOTIFICATIONS` | Notifikasi foreground service. |
| `RECEIVE_BOOT_COMPLETED` | Auto-start setelah boot. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Meminta pengecualian optimasi baterai. |

Permission yang tidak lagi digunakan:

- `NEARBY_WIFI_DEVICES`
- Wi-Fi Aware permission
- Nearby Connections runtime

## 13. UI Aplikasi

### 13.1 Splash Screen

Fungsi:

- Mengecek kondisi awal aplikasi.
- Mengarahkan ke onboarding, permission, atau home.

### 13.2 Onboarding Screen

Fungsi:

- Menjelaskan fungsi utama aplikasi kepada pengguna baru.

### 13.3 Permission Screen

Fungsi:

- Meminta izin lokasi, Bluetooth, notifikasi, dan battery optimization.
- Memberi informasi kenapa permission diperlukan untuk BLE relay.

### 13.4 Home Screen

Fungsi:

- Tombol utama `SEND SOS`.
- Menampilkan status BLE scan, BLE advertise, dan gateway.
- Tab pesan.
- Tab peta.
- Tab log.
- Tombol manual sync.
- Tombol BLE relay toggle.

### 13.5 BLE Relay Monitor

Nama route masih `/message_log`, tetapi layar sekarang adalah BLE relay monitor.

Fungsi:

- Menampilkan pesan yang tersimpan.
- Menampilkan peta.
- Menampilkan status BLE scan dan advertising.
- Menampilkan log relay.

## 14. Pengujian

### 14.1 Unit Test

File:

```text
test/ble_protocol_test.dart
```

Yang diuji:

- Pack/unpack SOS 17 byte.
- Pack/unpack ACK 17 byte.
- Payload invalid tanpa header `RM` ditolak.
- ACK lama tidak menghentikan pesan lokal yang lebih baru.
- ACK baru valid untuk menghentikan pesan lama.

Command:

```bash
flutter test
```

Status terakhir:

```text
All tests passed.
```

### 14.2 Static Analysis

Command strict:

```bash
flutter analyze
```

Catatan:

- Strict analyze masih menampilkan lint info seperti:
  - `avoid_print`
  - `withOpacity` deprecated
  - beberapa style lint lama
- Tidak ada error build-blocking pada pengecekan non-fatal.

Command non-fatal yang sudah berhasil:

```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
```

### 14.3 Android Build

Command:

```bash
flutter build apk --debug
```

Output:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Status terakhir:

```text
Build debug APK berhasil.
```

### 14.4 Manual Test Dengan Perangkat Fisik

Minimal perangkat:

- 2 HP Android.
- Lebih baik 3 HP Android untuk menguji relay multi-hop.

Skenario 1: SOS offline langsung

1. Matikan internet pada HP A dan HP B.
2. Buka aplikasi di HP A.
3. Tekan `SEND SOS`.
4. Pastikan BLE advertising aktif.
5. Buka aplikasi di HP B dan pastikan permission sudah diberikan.
6. HP B harus menerima payload SOS.
7. HP B menyimpan pesan ke database lokal.
8. HP B otomatis advertise ulang payload tersebut.

Skenario 2: Opportunistic gateway

1. HP A offline dan mengirim SOS.
2. HP B menerima SOS.
3. Nyalakan internet pada HP B.
4. HP B melakukan sync ke server.
5. Server memberi ACK.
6. HP B mengiklankan ACK via BLE.
7. HP A menerima ACK.
8. HP A menghentikan broadcast jika timestamp ACK valid.

Skenario 3: ACK lama tidak mematikan SOS baru

1. HP A mengirim SOS pertama.
2. Server/HP B menghasilkan ACK untuk SOS pertama.
3. HP A membuat SOS baru dengan timestamp lebih baru.
4. HP A menerima ACK lama.
5. Sistem harus mengabaikan ACK lama.
6. SOS baru tetap diiklankan.

Skenario 4: Background relay

1. Buka aplikasi di HP B dan berikan semua izin.
2. Pindahkan aplikasi ke background.
3. HP A mengirim SOS.
4. HP B harus tetap dapat menerima payload melalui BLE scan background.
5. HP B harus menyalakan service dan relay otomatis.

Skenario 5: Boot receiver

1. Berikan semua izin pada HP B.
2. Restart HP B.
3. Pastikan background service dapat dimulai setelah boot.
4. Pastikan BLE scan dapat berjalan kembali.

## 15. Variabel Evaluasi Skripsi

Variabel bebas:

- Jumlah perangkat: 2, 3, 4, 5 node.
- Jarak antar perangkat: 1 m, 5 m, 10 m, 20 m, 30 m.
- Kondisi jaringan: semua offline, satu gateway online, semua online.
- Kondisi aplikasi: foreground, background, setelah boot.
- Status pesan: active, cancelled, resolved.

Variabel terikat:

- Success rate penerimaan payload.
- Latency penerimaan SOS.
- Latency relay.
- Latency sync ke server.
- Latency penyebaran ACK.
- Jumlah duplikasi pesan.
- Akurasi status pesan.
- Konsumsi baterai.
- Stabilitas background service.

Metrik yang disarankan:

| Metrik | Cara Ukur |
| --- | --- |
| Delivery success rate | Jumlah payload diterima / jumlah payload dikirim. |
| Latency penerimaan | Waktu advertise sampai pesan tersimpan di penerima. |
| Latency gateway | Waktu pesan diterima node online sampai tersimpan server. |
| ACK latency | Waktu server ACK sampai broadcast berhenti. |
| Jarak efektif | Jarak maksimum payload masih diterima stabil. |
| Duplicate rate | Jumlah payload duplicate yang masuk sebelum deduplikasi. |
| Battery impact | Perubahan baterai selama periode pengujian. |

## 16. Keamanan Dan Privasi

Data yang disebarkan lewat BLE:

- Sender CRC.
- Timestamp.
- Latitude.
- Longitude.
- Status SOS.
- Flags.

Catatan keamanan:

- Payload BLE saat ini bersifat ringkas dan tidak terenkripsi.
- Dependency `encrypt` tersedia, tetapi enkripsi payload belum menjadi bagian inti.
- Karena payload hanya 17 byte, enkripsi penuh perlu desain tambahan.
- Untuk skripsi S1, batasan ini bisa dijelaskan sebagai ruang pengembangan.

Risiko:

- Lokasi pengguna tersebar ke perangkat sekitar.
- Payload dapat dibaca perangkat lain yang tahu format `RM`.
- Sender ID asli tidak dikirim, hanya CRC 32-bit.

Rekomendasi pengembangan:

- Tambahkan signature/HMAC ringkas jika ukuran payload memungkinkan.
- Tambahkan rotasi identifier.
- Tambahkan mode privasi.
- Tambahkan validasi backend untuk mencegah spoofing.

## 17. Batasan Sistem

Batasan teknis:

- BLE advertising tidak menjamin semua perangkat pasti menerima payload.
- Perangkat penerima harus berada dalam jangkauan BLE.
- Perangkat penerima harus melakukan scanning.
- Background BLE dipengaruhi vendor Android dan battery optimization.
- Payload 17 byte membatasi informasi yang dapat dikirim.
- Timestamp BLE menggunakan kompresi 24-bit dan resolusi detik.
- Akurasi lokasi bergantung pada GPS/perangkat.
- Server tetap dibutuhkan untuk pusat data online.

Batasan implementasi saat ini:

- Fokus utama Android.
- iOS/web/desktop bukan target utama untuk BLE background.
- Strict analyzer masih memiliki lint info lama.
- Enkripsi payload belum diaktifkan.
- Pengujian perangkat fisik tetap wajib untuk validasi BLE sungguhan.

## 18. Alasan Tidak Menggunakan Nearby Connections Dan Wi-Fi Aware

Versi sebelumnya sempat memiliki:

- Nearby Connections.
- Wi-Fi Aware.
- P2P berbasis koneksi langsung.

Alasan dihapus:

- Fokus skripsi menjadi lebih tajam.
- BLE advertising lebih connectionless.
- BLE tidak butuh pairing.
- BLE cocok untuk broadcast singkat ke perangkat sekitar.
- BLE relatif hemat daya.
- Pengujian menjadi lebih sederhana dan terukur.
- Wi-Fi Aware tidak tersedia di semua perangkat Android.
- Nearby Connections membutuhkan mekanisme discovery/koneksi yang lebih berat.

Desain terbaru:

```text
Offline communication = BLE Advertising + BLE Scanning only
Online communication  = HTTP API when internet exists
Background retry      = WorkManager
Local persistence     = SQLite
```

## 19. Command Developer

Install dependency:

```bash
flutter pub get
```

Jalankan test:

```bash
flutter test
```

Analisis non-fatal:

```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
```

Build APK debug:

```bash
flutter build apk --debug
```

Cari referensi P2P/Nearby/Wi-Fi Aware:

```bash
rg "nearby_connections|NativeWifiAwareManager|WifiAwareAdvertiserService|MeshService|startP2PSync|NEARBY_WIFI_DEVICES|WIFI_AWARE|P2P|Nearby" lib android/app/src/main/kotlin android/app/src/main/AndroidManifest.xml pubspec.yaml test
```

Hasil yang diharapkan:

- Tidak ada referensi runtime P2P/Nearby/Wi-Fi Aware.
- Yang boleh muncul hanya istilah BLE internal seperti `kResqMeshServiceUuidString`.

## 20. Rekomendasi Bab Skripsi

### Bab 1: Pendahuluan

Isi:

- Latar belakang bencana dan masalah komunikasi.
- Keterbatasan jaringan seluler/internet.
- Kebutuhan SOS offline.
- Rumusan masalah.
- Tujuan penelitian.
- Manfaat penelitian.
- Batasan masalah.

Rumusan masalah contoh:

1. Bagaimana merancang sistem SOS berbasis BLE advertising yang dapat berjalan tanpa internet?
2. Bagaimana mekanisme relay otomatis dapat menyebarkan payload SOS antar perangkat?
3. Bagaimana mekanisme opportunistic gateway mengirim SOS ke server saat internet tersedia?
4. Bagaimana ACK berbasis timestamp dapat menghentikan broadcast pesan lama tanpa mematikan pesan baru?

### Bab 2: Tinjauan Pustaka

Isi:

- Bluetooth Low Energy.
- BLE Advertising.
- Connectionless communication.
- Store-and-forward.
- Opportunistic networking.
- Disaster communication.
- SQLite mobile.
- Android foreground service.
- WorkManager.

### Bab 3: Metodologi

Isi:

- Metode R&D atau DSRM.
- Analisis kebutuhan.
- Perancangan arsitektur.
- Perancangan protokol payload.
- Perancangan database.
- Perancangan pengujian.

### Bab 4: Implementasi Dan Pengujian

Isi:

- Implementasi BLE protocol.
- Implementasi BLE relay.
- Implementasi background service.
- Implementasi WorkManager.
- Implementasi gateway sync.
- Hasil unit test.
- Hasil uji perangkat fisik.
- Tabel success rate dan latency.

### Bab 5: Kesimpulan Dan Saran

Isi:

- Kesimpulan performa sistem.
- Kelebihan BLE-only.
- Keterbatasan.
- Saran pengembangan:
  - Enkripsi payload.
  - Multi-packet payload.
  - Optimasi duty cycle.
  - Dashboard rescue team.
  - Uji lebih banyak perangkat.

## 21. Status Implementasi Saat Ini

Sudah ada:

- BLE-only connectionless core.
- Payload SOS 17 byte.
- Payload ACK 17 byte.
- BLE scan native Android.
- BLE advertising native Android.
- Background service.
- Boot receiver.
- Connectivity receiver.
- SQLite local database.
- WorkManager retry sync.
- Opportunistic gateway.
- ACK timestamp validation.
- BLE relay otomatis.
- Monitor BLE relay.
- Unit test BLE protocol.
- Debug APK build berhasil.

Belum selesai atau perlu penelitian lanjutan:

- Pengujian fisik multi-device.
- Pengukuran baterai formal.
- Pengukuran jarak formal.
- Enkripsi payload.
- Dokumentasi hasil eksperimen.
- Pembersihan lint strict analyzer.

## 22. Kesimpulan

Project ResQMesh versi BLE-only sudah memiliki arah yang kuat untuk dijadikan topik skripsi S1 Teknologi Informasi.

Nilai utama project:

- Masalah nyata: komunikasi SOS saat bencana.
- Solusi teknis: BLE advertising connectionless.
- Mekanisme relay: perangkat penerima otomatis menyimpan dan mengiklankan ulang pesan.
- Opportunistic gateway: perangkat online mengirim data ke server.
- ACK timestamp: broadcast dihentikan hanya jika pesan lokal tidak lebih baru.
- Evaluasi jelas: success rate, latency, jarak, baterai, dan reliabilitas background.

Formulasi singkat:

```text
ResQMesh adalah aplikasi SOS offline-first berbasis BLE advertising yang memungkinkan perangkat Android menyebarkan pesan darurat secara connectionless, menyimpan data secara lokal, melakukan relay otomatis antar perangkat, dan melakukan sinkronisasi ke server secara oportunistik saat internet tersedia.
```
