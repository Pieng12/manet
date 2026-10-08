# Desain Adaptasi Trickle/MPL BLE

## Audit Acuan

Branch MPL, HEAD acuan `6d1b9b72c826d56bfb20789c128e8182062634db`.
`NeighborStatusSchedule` adaptive_v2 sebelumnya adalah backoff discovery/empty
retry/heartbeat, tanpa c/k CONTROL dan expiration interval. DATA historis
trickle_neighbor_status memilih INITIAL_FORWARD_PENDING/FRESH_MISSING/
UNKNOWN_OR_NO_NEIGHBORS dan suppress ALL_OBSERVED_HAVE. Jalur tersebut tetap
historis. Mode baru tidak menggunakan keputusan HAVE sebagai pengganti c/k.

Dasar primer: [RFC 6206 bagian 4-5](https://www.rfc-editor.org/rfc/rfc6206.html),
[RFC 7731 bagian 4.3, 7-10](https://www.rfc-editor.org/rfc/rfc7731.html).
Tidak ada IPv6, ICMPv6, MPL wire format, atau interoperabilitas MPL standar.

| Fitur | RFC/bagian | Pemetaan kode | Adaptasi/ekstensi | Alasan dan batasan |
| --- | --- | --- | --- | --- |
| Listen-only, random t, c/k, doubling | 6206 4.2-5 | MplTimer Dart/C++ | Mekanisme dasar | t pada [I/2,I); reset saat Imin tidak memilih t ulang |
| Timer DATA per entri dan e | 7731 9.2 | MplScheduler.data | Mekanisme dasar di transport BLE | e menghitung interval selesai, termasuk suppressed |
| Timer CONTROL per scope | 7731 10.2 | MplScheduler.control | Mekanisme dasar di transport BLE | Bukan heartbeat tetap atau adaptive_v2 yang diganti nama |
| Perbandingan inventory | 7731 10.1/10.3 | receive/covers | Adaptasi explicit inventory | Bukan Seed Info bitmap/min-seqno; partial/ambigu tidak menjadi negative evidence |
| Identitas buffer | 7731 7-9 | StateIdentity/MessageKey | Adaptasi identitas aplikasi | Sender CRC dan timestamp/status/flags bukan sequence burst pemancar |
| Dedup burst | 6206 consistency; 7731 forwarding | NeighborController | Adaptasi BLE | scope/transmitter/boot/sequence; tidak memakai alamat BLE sebagai identitas permanen |
| Discovery | 7731 mismatch/reactivation | discover/restartStatus | Ekstensi BLE | Dua kesempatan CONTROL terlindungi setelah start/aktif kembali; retry terbatas |
| Repair cabang | 7731 10.3 | repairs/tick/dataDue | Ekstensi repair override | c>=k boleh dilewati hanya untuk peer MISSING fresh; budget/cooldown/expiry per episode |
| Deficit lokal | 7731 10.3 | demands/controlDue | Ekstensi perlindungan terbatas | Tidak membuat DATA palsu; CONTROL masih dalam interval dan timer tetap expire |
| Coalescing DATA | Tidak diterapkan di mode ini | adaptive_v2 historis | Tidak diaktifkan untuk MPL v1 | DATA satu state tidak membuktikan inventory semua peer sama |
| Satu radio owner | Tidak ditentukan RFC | BleAdvertiserService/main.cpp | Adaptasi BLE | CONTROL ditunda untuk DATA due; callback native menentukan sukses |
| Freshness/retensi | Pilihan aplikasi di atas RFC | NeighborController/buffer durable | Ekstensi penelitian | UNKNOWN tidak otomatis reset seluruh DATA; tanpa TTL/hop/count cutoff |

## Identitas, Graph, Dan Buffer

S=android-source; A=esp-r1a; B=esp-r1b; C=esp-r2a; D=esp-r2b;
E=esp-destination. E tetap RELAY. Allowlist graph adalah filter testbed yang
sama di semua metode, bukan routing atau bukti peer menerima DATA. Bukan
bukti isolasi RF atau jangkauan fisik tiga hop.

Inner SOS tetap 17 byte; envelope DATA 22 byte, sehingga semua metode graph
memakai 39 byte. STATUS 22-86 byte, hingga delapan StateIdentity.
Inventory complete hanya untuk snapshot seluruh buffer; snapshot terpotong
adalah partial. Inventory ambigu dengan beberapa state sender sama ditolak
sebagai bukti pengetahuan, bukan dianggap kosong. Tidak ada fragmentasi baru.

Android mengambil inventory dari SOS durable yang belum ACK/synced, dan queue
mengambil database yang sama. Firmware aplikasi saat ini menyimpan satu SOS
penelitian; inventory firmware hanya mengiklankan packet yang tersedia untuk
TX. Core timer diuji dua state tetapi ini tidak mengklaim firmware aplikasi
multi-SOS penuh. Profil eksperimen membuat satu SOS per trial.

Buffer bertahan setelah timer expire. Pada Android, pemulihan owner membangun
timer dari queue durable; pada ESP, state dipulihkan dari NVS sesuai jalur lama.
Timer/e tidak dipersistenkan: restart lokal memulai timer/discovery baru dan
biayanya tetap tercatat. Retensi `persistent_until_supersession_ack_admin`:
ACK/state lebih baru/penghapusan administratif dapat mengganti buffer, bukan
expiry timer. Reset trial penelitian tetap prosedur administratif lama.
Database utama tetap versi 14; tidak diperlukan tabel/migrasi baru.

## State Machine

DATA: insert buffer -> active Imin,c=0,e=0 -> listen-only -> opportunity
c<k ALLOWED atau c>=k SUPPRESSED -> native requested -> success/failed retry
-> akhir interval e++ -> I mengganda atau TIMER_STOPPED. Suppression/stop
tidak menghapus buffer. DATA pertama yang baru disimpan bukan duplicate c.
DATA konsisten berikutnya hanya menambah c sekali per burst valid di interval
fisik yang sama. CONTROL tidak menambah c DATA.

CONTROL: discovery/inventory changed/mismatch -> active -> listen-only ->
c/k decision -> callback/retry -> e++/doubling -> stopped. Complete inventory
dua arah tidak mempunyai state baru untuk ditawarkan berarti konsisten.
Lokal punya/peer kurang memicu repair; lokal kurang/peer punya memicu ringkasan
deficit dan menunggu DATA asli. Partial, replay, salah scope, stale, ambigu
tidak menjadi bukti konsisten lengkap. UNKNOWN bukan HAVE atau MISSING.

Repair: bukti MISSING valid -> episode (scope,state,peer,boot,inventory) -> reset/wake
DATA relevan -> maksimal dua override DATA sukses dan dua evaluasi reset
berjeda -> HAVE peer yang sama, budget habis, supersession atau expiry.
Snapshot identik dengan sequence baru tidak membuka episode tak terbatas.
Perubahan inventory/boot nyata membentuk episode baru. Reset Imin tidak
memindahkan t. Wake cooldown tidak bergantung pada datangnya frame baru.
Inventory episode memakai urutan state yang dinormalisasi, bukan sequence
STATUS atau generation inventory lokal. Snapshot partial/replay/stale tidak
membuka episode baru.

Discovery: trial start/scanner ON/node ON -> jitter -> dua CONTROL sukses
terlindungi dari c/k; tiga retry native gagal per interval. Kehilangan seluruh
bootstrap di radio tetap dapat menggagalkan recovery. Probe default nonaktif;
opsional probe mempunyai interval dan jumlah maksimum, seluruhnya berbiaya.
Pada MPL saja, transisi participation OFF -> ON memperbarui incarnation yang
disimpan dan memulai sequence dari 1 pada frame berikutnya. Scanner OFF pada
S1 tetap dapat mengirim STATUS lama; ketika scanner ON, incarnation baru
membedakannya dari episode yang budget-nya habis sebelum scanner siap.
Pengulangan ON tidak memperbarui incarnation atau timer discovery. Incarnation
disimpan sebelum frame discovery baru; overflow/kegagalan simpan menghentikan
aktivasi. Buffer SOS, scope, payload dan metode pembanding tidak di-reset.
`local_boot_id` pada respons/event dan `peer_boot` pada bukti RX memudahkan audit.

## Parameter Kandidat

Semantik versioned `resqmesh-trickle-mpl-v1`; angka berikut pilihan pilot,
bukan angka wajib RFC. Manifest/fingerprint/readiness/Excel mencatat nilainya.

| Parameter | Default | Alasan/trade-off |
| --- | --- | --- |
| DATA Imin/Imax efektif/k/e limit | 8000/256000 ms/1/5 | Sejajar baseline; timer selesai setelah 248 s bila tanpa reset |
| CONTROL Imin/Imax efektif/k/e limit | 4000/32000 ms/1/4 | Discovery lebih cepat; settled berhenti sekitar 60 s + jitter |
| Repair cooldown/budget/expiry | 8000 ms/2/60000 ms | Repair cabang terbatas tanpa starvation cooldown global |
| Bootstrap/jitter | 2/0-1500 ms | Inventory kosong tidak selalu hilang karena mendengar peer kosong |
| Native retry/limit | 1000 ms/3 per interval | Failure bukan TX sukses atau konsumsi budget sukses |
| Probe interval/limit | 60000 ms/0 | Tidak memakai heartbeat tak terbatas untuk menutupi loss |
| Freshness | 150000 ms | Dari RX fisik monotonic valid; expiry UNKNOWN tidak reset storm |
| CONTROL burst/DATA burst | 500/2000 ms | Sama profil graph historis; kesempatan DATA didahulukan |

Tanpa reset, setiap node mempunyai paling banyak empat kesempatan CONTROL
dalam rangkaian awal (~24 kesempatan enam node); suppression dapat mengurangi
TX, bootstrap melindungi dua sukses. Inventory changed/repair/restart dapat
menambah biaya; bukan batas total overhead sesi. Discovery pertama biasanya
2-5,5 s setelah aktif kembali, lalu DATA repair 4-8 s setelah reset Imin bila
slot tersedia. Loss/native failure/queue/callback dapat memperpanjangnya.
Ini estimasi jadwal, bukan jaminan recovery atau DSR.

## Clock, Callback, Dan Logging

ESP deadline menggunakan selisih uint32 wrap-safe. Android mengonversi waktu
RX elapsedRealtime native ke clock monotonic owner menggunakan pembacaan
elapsedRealtime sekarang; tidak mengurangkan wall-clock untuk freshness.
Waktu native invalid/tidak tersedia dicatat dan tidak menghalangi transaksi
SOS/ACK durable. Tidak memperbarui freshness dari polling/TX lokal/replay.

Native DATA/CONTROL diperiksa lagi setelah encoding/logging; callback lama
generation atau inventory tidak menghabiskan budget baru. TX fisik yang benar
terjadi tetap dicatat walaupun callback terlambat, bukan disembunyikan.
Opportunity terlambat/deferred/missed tercatat. BLE tetap satu owner background;
UI dan controller tidak memilih suppression dari hasil global.

Event MPL interval/c/opportunity/native/timer/repair/discovery/classification
memiliki field relevan (scope, timer key/generation/I/t/c/k/e, peer/boot,
physical RX, inventory generation, budget). Event canonical DATA/STATUS
BURST_STARTED saja membentuk overhead; alias MPL_NATIVE_STARTED tidak dihitung
sebagai TX tambahan. Data mentah tetap diekspor untuk pemeriksaan ulang.

## Evaluasi

DSR=U/(M*5)*100; LDR=(R-U)/R*100 (R=0 kosong); delay native RX pertama dikoreksi
clock minus DATA sumber pertama sukses; overhead DATA+CONTROL enam node pada
window 180 detik sejak TX sumber pertama, setup terpisah.
Recovery dari ON terkonfirmasi ke RX pertama node yang diperturbasi, bukan
waktu command request. Gagal tidak diberi delay nol. Burst bukan paket RF,
airtime, atau energi. Coded requested/accepted bukan bukti S8/125 kbps.

Pilot 27 dan smoke 9 terpisah dari utama 135. Jika CONTROL melebihi penghematan
DATA, hasil bukan lebih hemat. Tuning k/e/control Imin/bootstrap/probe harus
diuji dalam sesi/fingerprint baru, bukan mengganti dataset utama dibekukan.
