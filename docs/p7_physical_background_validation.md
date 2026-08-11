# P7 Physical Android Background Validation

Dokumen ini adalah checklist uji perangkat fisik. Unit test, source test,
analyze, dan build APK tidak membuktikan perilaku BLE/background Android di
lapangan. Semua skenario di bawah berstatus `NOT RUN` sampai ada bukti dari
perangkat fisik.

Status yang boleh dipakai: `NOT RUN`, `PASS`, `FAIL`, `BLOCKED`.

P9 menambahkan Research Monitor untuk membuat session/trial dan export evidence
CSV/JSON. Gunakan export tersebut sebagai bukti saat skenario fisik benar-benar
dijalankan. Status di bawah tetap `NOT RUN` sampai ada evidence perangkat fisik.

## Evidence Wajib

Untuk setiap skenario, simpan:

- model perangkat, versi Android, mode forwarding, dan build APK;
- logcat timestamp untuk receiver, native inbox, worker/service, scheduler, dan
  advertiser;
- screenshot Relay Monitor yang memperlihatkan queue, native inbox, scheduler,
  advertiser, dan manufacturer ID;
- dump/export SQLite atau export experiment JSON/CSV;
- capture ESP32 atau nRF scanner untuk sender CRC, timestamp, status, hop, RSSI,
  dan waktu observasi.

## Scenario A - ESP32 -> Android While FGS Active

Status: `NOT RUN`

Topology: `ESP32 TX/relay -> Android`

Steps:

1. Jalankan ResQMesh dengan foreground service aktif.
2. Broadcast packet 17-byte valid dari ESP32.
3. Catat logcat mulai dari PendingIntent scan sampai relay attempt.
4. Amati iklan Android dengan ESP32/nRF scanner.

Expected evidence:

- Android PendingIntent scanner menerima packet.
- Sender CRC, timestamp, status, dan hop mentah benar.
- Message masuk SQLite dan tampil di Relay Monitor.
- Relay queue berisi message baru.
- Android mengiklankan hop+1.
- ESP32/nRF melihat packet relay Android.

## Scenario B - FGS Stopped, Headless Worker Path

Status: `NOT RUN`

Topology: `ESP32 -> Android`

Precondition:

- Stop ResQMesh foreground service.
- Catat state process/FGS sebelum packet dikirim.

Expected sequence:

```text
BLE scan PendingIntent
-> NativeBleInbox stored
-> NativeBleInboxWorker started
-> headless Dart started
-> BLE packet processed
-> SQLite committed
-> relay queue committed
-> immediate relay attempt
-> inbox acknowledged
```

Required evidence:

- logcat timestamps untuk semua tahap;
- native inbox state sebelum/sesudah;
- queue state dan next eligible time;
- advertiser state dan last native error;
- packet relay Android diamati oleh ESP32/nRF.

## Scenario C - Screen Off

Status: `NOT RUN`

Steps:

1. Matikan layar selama interval terukur, misalnya 5 menit.
2. Kirim packet baru dari perangkat fisik lain.
3. Jangan buka ResQMesh selama uji berjalan.

Expected evidence:

- receive/store/relay terjadi saat layar mati;
- logcat menunjukkan path background yang dipakai;
- Relay Monitor setelah dibuka sesuai dengan event yang sudah tercatat.

## Scenario D - App Removed From Recent Apps

Status: `NOT RUN`

Steps:

1. Swipe ResQMesh dari recent apps.
2. Jangan buka aplikasi manual.
3. Kirim packet dari ESP32 atau Android kedua.

Expected evidence:

- packet masuk NativeBleInbox;
- recovery berjalan melalui worker/service yang diizinkan OS;
- queue tidak hilang;
- relay attempt tercatat atau kegagalan terklasifikasi.

## Scenario E - Bluetooth OFF -> ON

Status: `NOT RUN`

Steps:

1. Siapkan packet di relay queue.
2. Disable Bluetooth.
3. Catat scheduler blocked state.
4. Tunggu sekitar 10 detik.
5. Enable Bluetooth.

Expected evidence:

- queue tetap ada;
- `next_eligible_at` tidak digeser 5 menit;
- setelah Bluetooth ON, packet langsung dipertimbangkan ulang;
- advertiser start atau failure terklasifikasi tanpa artificial delay.

## Scenario F - Permission Revoked -> Granted

Status: `NOT RUN`

Steps:

1. Revoke permission BLE/location/notifikasi yang relevan.
2. Kirim packet sampai Native Inbox memiliki pending item.
3. Jalankan recovery.
4. Grant permission kembali.

Expected evidence:

- Worker tidak spin/retry terus menerus saat permission hilang;
- Native Inbox tetap pending;
- setelah permission granted, explicit recovery trigger enqueue worker;
- pending inbox diproses dan di-ack setelah hasil non-retryable.

## Scenario G - Duplicate Persistence

Status: `NOT RUN`

Steps:

1. Broadcast exact 17-byte packet yang sama selama beberapa menit.
2. Catat native inbox count setiap interval.

Expected evidence:

- jumlah object Native Inbox tidak tumbuh linear;
- `duplicate_count` atau `last_seen_at` meningkat untuk exact duplicate;
- SQLite tidak membuat logical message berulang;
- experiment duplicate metrics meningkat benar.

## Scenario H - Stale Resurrection Prevention

Status: `NOT RUN`

Steps:

1. Kirim `ACTIVE timestamp A`.
2. Kirim `CANCELLED timestamp B`, dengan `B > A`.
3. Replay `ACTIVE timestamp A`.

Expected evidence:

- old ACTIVE diklasifikasi `STALE`;
- CANCELLED tetap latest state;
- old ACTIVE tidak masuk relay queue;
- tidak terjadi resurrection.

## Scenario I - Android Physical Relay

Status: `NOT RUN`

Topology: `Android A -> Android B -> ESP32 observer`

Expected evidence:

- Android A advertises hop 0;
- Android B receives hop 0;
- Android B stores it;
- Android B advertises hop 1;
- ESP32 sees same sender CRC/timestamp/status and hop 1.

## Scenario J - Mixed Multi-Hop

Status: `NOT RUN`

Topology: `Android A -> ESP32 R1 -> Android B -> ESP32 R2`

Expected hop sequence: `0 -> 1 -> 2 -> 3`, tergantung node observer akhir.

Record:

- sender CRC;
- timestamp;
- status;
- incoming hop;
- outgoing hop;
- RSSI;
- receive timestamp;
- advertise timestamp.

## Scenario K - ACK Propagation

Status: `NOT RUN`

Steps:

1. Buat `ACTIVE`.
2. Relay across nodes.
3. Generate `CANCELLED` atau `RESOLVED` ACK.
4. Propagate ACK.
5. Replay old SOS.

Expected evidence:

- ACK menghentikan original SOS queue;
- tombstone menekan old SOS replay;
- ACK disimpan dan direlay sebagai persistent anti-message;
- ACK termination latency tercatat.
