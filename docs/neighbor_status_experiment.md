# Profil Pengendalian Retransmisi Berdasarkan Tetangga

Implementasi lokal pada branch `metode-penerimaan`, berbasis
`6f5b1c83e6fc6a395d5b1140924f35c0f6206f9c`. Ini mekanisme eksperimen,
bukan bukti efisiensi atau jaminan pengiriman. Panduan operasional:
[Windows](neighbor_status_windows.md).

## Versi Dan Kompatibilitas

- Profil baru: `neighbor_graph_v1`; transport `resqmesh-neighbor-v1`;
  `neighbor_design_version=1`; pengukuran `all-node-burst-v1`.
- Inner SOS/ACK tetap RM 17 byte dan epoch `resqmesh-2026-06-01`.
  **Total DATA baru 39 byte**, bukan 17 byte.
- Database protokol Android tetap versi **14**. Tidak ada migrasi tabel,
  penghapusan database/NVS/dataset, commit, push, atau flash otomatis.
- Profil H1/H2/H3, estimator RX berbasis gap, rumus historis, serta Uji Jarak
  tetap menggunakan jalur legacy. Jangan menggabungkan angka kedua profil.
- Keempat metode dalam profil baru memakai envelope DATA dan graph yang sama.
  STATUS periodik hanya dipancarkan metode `trickle_neighbor_status` dan masuk
  overhead; ia bukan ACK penyelesaian SOS.
- Build ID baru adalah 12 karakter dari SHA256 isi source yang dibekukan,
  bukan klaim bahwa working tree identik dengan commit referensi.

## Metode Dan Keputusan

| Metode | Kesempatan DATA | Suppression |
|---|---|---|
| basic_flooding | Pertama eligible segera; berikutnya burst 2 s + jeda 2 s + jitter 300-1500 ms | Tidak |
| trickle_no_suppression | Imin 8 s, Imax 256 s, t acak [I/2,I) | Tidak |
| trickle | Interval/t yang sama, k=1 | c >= k |
| trickle_neighbor_status | Interval/t yang sama | Status tetangga teramati |

Baseline tidak diberi first-forward override atau controller status. Dalam graph
baru, DATA dengan StateIdentity sama dari **relay lain** dapat menaikkan c,
hanya pada interval yang berlaku dan sekali per burst. Pengulangan sumber asli
dan STATUS tidak menaikkan c. Ini adaptasi aplikasi, bukan aturan hop dari RFC.
Core pemilihan t, interval doubling, dan kebijakan keterlambatan tidak diganti.

Keputusan metode usulan pada kesempatan Trickle:

1. DATA belum pernah berhasil dimulai: izinkan first forwarding pada t normal.
   Native start gagal tidak menyelesaikan pending, tidak menghapus pesan,
   dan memakai retry/backoff yang sudah ada, bukan busy-loop.
2. Ada MISSING segar: izinkan DATA, walau tetangga lain HAVE.
3. Ada UNKNOWN atau belum ada tetangga: izinkan kesempatan DATA mengikuti Trickle.
4. Minimal satu tetangga teramati dan seluruhnya HAVE segar: suppress DATA;
   SOS tetap persisten dan STATUS tetap dijadwalkan.

DATA valid membuktikan pemancar mempunyai state itu. STATUS lengkap yang
memuatnya memberi HAVE; snapshot lengkap tanpa state memberi MISSING.
Snapshot parsial, kedaluwarsa, tanpa observasi, atau scope salah bukan MISSING.
State lebih baru pada peer tidak diperbaiki mundur. Tetangga kedaluwarsa
tetap dicatat UNKNOWN, tidak dihapus untuk mengklaim semua sudah menerima.

Repair dari perubahan/new peer digabung menjadi satu kebutuhan broadcast.
Reset hanya di atas Imin, setelah cooldown; salinan burst atau snapshot identik
tidak mengulang reset. Tidak ada ACK individual untuk setiap repetisi RF.

## Format Binary

Seluruh integer big-endian. Manufacturer ID tetap `0xFFFF` untuk eksperimen.
Panjang di bawah ini adalah manufacturer value, belum termasuk header AD.

| Offset | Byte | Makna |
|---|---:|---|
| 0 | 2 | `RN` = `52 4e` |
| 2 | 1 | Versi 1 |
| 3 | 1 | DATA=0, STATUS=1 |
| 4 | 4 | CRC32 node_id pemancar stabil, bukan source SOS |
| 8 | 4 | Incarnation persisten, nonzero |
| 12 | 4 | Sequence burst nonzero |
| 16 | 4 | CRC32 trial_id perangkat, nonzero |
| 20 | 1 | Jumlah inventory, 0..8; DATA=0 |
| 21 | 1 | Complete 0/1; DATA=1 |
| 22 | 17 atau 8*n | Inner RM atau inventory |

Entri inventory: sender_crc 4 byte, compact epoch seconds 3 byte, flags/status
1 byte (status pada 6 bit rendah, server=0x40, ACK=0x80). ACK ACTIVE ditolak.
STATUS kosong 22 byte; maksimum 86 byte. Android memeriksa kapasitas aktual
advertiser; readiness profil mensyaratkan minimum 90 byte termasuk header AD.
Inventori Android lebih dari delapan state ditandai **tidak lengkap**;
firmware tetap satu slot SOS. STATUS tidak diteruskan sebagai SOS.

Golden vectors (source `0x12345678`, epoch+42 s, koordinat nol, ACTIVE, hop 1;
transmitter=1, boot=2, sequence=3, scope=4):

```text
DATA: 524e0100000000010000000200000003000000040001524d1234567800002a0000000000000101
STATUS kosong: 524e0101000000010000000200000003000000040001
STATUS satu state: 524e01010000000100000002000000030000000401011234567800002a01
```

Identitas RX adalah receiver + scope + transmitter + incarnation + sequence.
MAC hanya metadata. Sequence sama sepanjang repetisi satu burst; wrap menaikkan
incarnation yang disimpan sebelum TX. Reboot menaikkan incarnation dan membuang
freshness/cache tetangga volatil; peers lama tidak dipercaya. Incarnation habis
atau gagal disimpan menolak TX, bukan memakai ID ulang. Konfigurasi memvalidasi
ID unik dan collision CRC untuk keenam node. CRC scope bukan autentikasi;
jangan menjalankan sesi lain dengan scope collision dalam RF testbed yang sama.

## Scheduler Dan Transport

DATA/STATUS memakai owner advertising yang sama (background isolate Android,
owner loop ESP, set 0). DATA due dipilih dahulu; STATUS 500 ms tidak dimulai
menjelang kesempatan DATA (cadangan 250 ms). Discovery tetap hidup walau queue
kosong, dan dapat mengambil sela interval. Perangkat harus memvalidasi margin
start radio ini lewat pilot; latency driver bukan jaminan real-time.

Callback NimBLE hanya decode/enqueue; perubahan state/repair dilakukan loop.
Scanner dipulihkan setelah burst selesai, dibatalkan, atau gagal. Gate partisipasi
nyata menghentikan scan/TX sesuai skenario dan tidak mereset pesan/trial.
Native inbox Android menyimpan RX fisik terlebih dahulu; parsing RN dan
idempotensi burst tidak memakai estimator MAC/gap legacy. Diagnostik gagal
tidak membatalkan commit SOS/ACK. Tidak ada hard TTL/hop/relay-count baru.
Satu SOS per trial wajib; snapshot/queue kapasitas bukan sistem routing baru.

Default pilot, **belum hasil optimasi empiris**:

| Parameter | Default | Tujuan |
|---|---:|---|
| status_period_ms | 12000 | Kontrol tidak setiap repetisi RF |
| status_burst_ms | 500 | Dua interval radio nominal; overhead terukur |
| freshness_ms | 45000 | Lebih dari dua periode; toleransi loss, lalu UNKNOWN |
| discovery_jitter_ms | 1500 | Kurangi sinkronisasi kontrol antarnode |
| reset_cooldown_ms | 8000 | Batasi reset storm, satu Imin |
| neighbor_capacity | 16 | Bounded; cukup bagi testbed enam node |

## Graph Dan Skenario

Graph dua arah: S-A, S-B, A-C, B-C, A-D, D-E.
S=`android-source`, A=`esp-r1a`, B=`esp-r1b`, C=`esp-r2a`, D=`esp-r2b`,
E=`esp-destination`. Kelima ESP adalah penerima **dan RELAY**, termasuk E.
Filter ID pemancar berlaku sebelum efek protokol/status/consistency/metrik.
SOURCE dapat memproses observasi; adjacency bukan oracle HAVE/MISSING.

- S0_MAIN: seluruh node aktif. Analisis utama, 4 metode x 15 = 60 trial.
- S1_DELAYED_RX: scanner D nyata OFF sejak sebelum trigger; ON setelah delay t0.
- S2_LATE_JOIN: TX/RX E nyata OFF, kemudian ON; state/trial tidak direset.
- Ketiganya: 15 blok x 12 kombinasi = 180 trial; pendukung terpisah dari utama.

Default window 180 s, delay 30 s, minimum recovery 120 s, quiet 5 s. Semua
metode memakai kondisi/window yang sama. Delay dimulai dari native callback
DATA pertama sumber (t0), bukan command/SOS_CREATED. Tentukan kecukupannya
lewat pilot sebelum membekukan config. Randomisasi seimbang per blok dengan
seed tetap; FAILED_DELIVERY sah dan tidak diulang sampai sukses.
INVALID khusus instrumentasi/prosedur (clock, serial, source start, scope,
log tidak lengkap, reset gagal). Smoke membolehkan FAILED_DELIVERY yang sah.

Ini BLE fisik dengan graph **logis**. Filter tidak menghilangkan interferensi RF,
tidak membuktikan isolasi fisik/hop jarak. Requested TX Android +1 dBm dan ESP
+20 dBm dipertahankan; gunakan nilai aktual dalam log. Coded PHY bukan bukti
S=8. Uji Jarak ESP->HP bukan bukti arah HP->ESP.

## Pengukuran Dan Arsip

Window `[t0,t0+durasi)`, koreksi clock host per node diperbarui setiap trial.
Sinkronisasi merekam offset dan estimasi batas ketidakpastian setengah RTT +1 ms
per node; bound pasangan dijumlahkan. Ini bukan kalibrasi presisi absolut.
Toleransi yang dikonfigurasi dicatat terpisah, tidak disamakan dengan bound.

- M: SOS unik sumber (wajib 1); N: lima target ESP.
- U: pasangan MessageKey/receiver yang menerima DATA valid di window.
- R: RX DATA logis valid pada target; satu receiver/transmitter/boot/seq/scope
  satu RX, RF repeat/replay tidak menggandakan R.
- DSR=100*U/(M*5); gagal tetap denominator.
- E2E=RX fisik pertama - TX DATA sumber pertama; rerata pasangan sukses saja.
  Gagal kosong, bukan nol/timeout. First RX masing-masing lima ESP ditampilkan.
- LDR=100*(R-U)/R, kosong jika R=0. STATUS/source RX/edge terlarang dikecualikan.
- Overhead=DATA_TX+CONTROL_TX yang berhasil dimulai seluruh enam node di window.
  REQUESTED/FAILED bukan TX. Kontrol sebelum t0 dicatat `setup_control_tx`.

Research Monitor membedakan pengetahuan lokal HP (peers teramati) dari ringkasan
network-wide yang dikirim controller setelah penggabungan log. Ringkasan tidak
dipakai algoritma dan bukan pengamatan live seluruh jaringan. UI tidak memiliki
scheduler kedua. Workbook `resqmesh_neighbor_analysis.xlsx` terpisah berisi
Overview, Metric Definitions, Trial Metrics, Method Scenario Summary, Receivers,
All Events, Participation, Method Parameters, Invalid Trials; JSON/CSV ikut
tersimpan. Raw per attempt immutable, termasuk attempt INVALID; log parsial
diselamatkan saat disconnect bila tersedia. Jangan menimpa output merge lama.

## Validasi Perangkat Yang Masih Wajib

Pengujian otomatis/build bukan hasil RF. Sebelum batch utama, buktikan:

1. Readiness keenam perangkat: build sama, radio Coded siap, scope/mode/role benar.
2. Inner source tidak berubah antarrelay; transmitter/boot/sequence cocok RX/TX.
3. Edge terlarang tidak menambah c/cache/metric, source dapat menerima STATUS.
4. Semua teramati HAVE suppress DATA tetapi STATUS tetap berjalan.
5. A mendengar C HAVE dan D MISSING: DATA diizinkan; empty late join memicu repair.
6. S1 scanner D benar OFF/ON dan S2 E TX/RX benar OFF/ON, confirmed dicatat.
7. Failed native start tidak menyelesaikan initial pending; scanner pulih.
8. Reboot/incarnation tidak mereuse burst; queue/SOS tetap persisten.
9. Raw lengkap, clock uncertainty masuk batas, rumus dihitung ulang cocok.
10. Ketiga baseline/Uji Jarak lama tetap berfungsi pada profil lama.

Tidak ada klaim semua pesan pasti sampai, keunggulan statistik, energi,
jangkauan maksimum, atau novelty global sebelum eksperimen yang sesuai.
