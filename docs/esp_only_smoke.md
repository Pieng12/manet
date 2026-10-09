# Smoke ESP-Only

Profil `esp_only_five_v1` hanya memeriksa firmware ESP. Hasilnya tidak menggantikan
validasi Android dan tidak boleh digabungkan dengan dataset utama.

## Perangkat dan skenario

| Label | Node | Peran |
| --- | --- | --- |
| S | esp-r1b | SOURCE |
| A | esp-r1a | RELAY / target |
| C | esp-r2a | RELAY / target |
| D | esp-r2b | RELAY / target |
| E | esp-destination | RELAY / target |

Graf logis dua arah: S-A, S-C, A-C, A-D, D-E. Semua node boleh berdekatan;
graf ini memakai allowlist, bukan isolasi RF. Tidak membuktikan S8.

| Skenario | Perlakuan | Window dari DATA sumber pertama |
| --- | --- | --- |
| S0_STABLE | Semua aktif | 180 detik |
| S1_BRANCH_DELAYED | D/E TX/RX OFF sebelum SOS, D lalu E ON detik 60 | 180 detik |
| S2_POST_DATA_STOP | E TX/RX OFF sebelum SOS, ON detik 300 | 420 detik |

Basic Flooding, Trickle, dan trickle_mpl masing-masing menjalani ketiga skenario:
9 trial dalam satu blok acak, tanpa penggantian attempt otomatis. Observasi saja
39 menit; persiapan/reset/ekspor menambah waktu. Hasil tidak dijamin unggul.

## Konfigurasi dan command

Contoh konfigurasi: `tools/experiment_controller/config.mpl.esp-only.smoke.example.json`.
Konfigurasi lokal harus memakai COM numerik yang dipetakan secara eksplisit,
firmware build ID yang sama pada lima ESP, dan session/output baru. Placeholder
akan ditolak. Firmware MPL yang sesuai sudah mendukung SOURCE; implementasi
profil ini tidak membutuhkan perubahan firmware atau APK.

Sebelum command di bawah, buat file lokal dari contoh bila belum tersedia.
Jangan langsung menyalin contoh lalu menjalankan smoke: ganti placeholder COM,
build ID, dan session terlebih dahulu. Pemetaan lama dan build lokal belum
membuktikan perangkat yang tersambung saat ini sama; readiness tetap wajib.

```powershell
$ConfigPath = 'experiment.mpl.esp-only.smoke.local.json'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Copy-Item -LiteralPath 'tools/experiment_controller/config.mpl.esp-only.smoke.example.json' -Destination $ConfigPath
    notepad $ConfigPath
    throw 'Isi COM, firmware_build_id, dan session_id; simpan lalu jalankan plan/readiness'
}
```

```powershell
py tools/experiment_controller/run.py discover --serial-only
$ConfigPath = 'experiment.mpl.esp-only.smoke.local.json'
$OutputDir = Join-Path $PWD ('experiment_output/mpl-esp-only-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
py tools/experiment_controller/run.py plan --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Plan gagal; jangan lanjut' }
py tools/experiment_controller/run.py readiness --config $ConfigPath --output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Readiness gagal; jangan lanjut' }
py tools/experiment_controller/run.py smoke --config $ConfigPath --output $OutputDir
$SmokeExit = $LASTEXITCODE
$Workbook = Join-Path $OutputDir 'smoke_merged/resqmesh_esp_only_analysis.xlsx'
if (Test-Path -LiteralPath $Workbook) { Start-Process -FilePath $Workbook }
if ($SmokeExit -ne 0) { throw 'Smoke belum siap; periksa delivery, core checks, dan bukti mekanisme' }
```

Laptop harus tetap hidup; tutup monitor serial lain sebelum mulai. Jangan
flash atau mencabut ESP selama batch. Trial asing yang masih aktif tidak
di-reset diam-diam. Jika dibatalkan/COM putus, periksa manifest dan
`partial_merged`; jika penghentian belum terkonfirmasi, matikan ESP sebelum
menjalankan sesi baru. Jangan menimpa dataset lama atau mengulang supaya
angka terlihat lebih bagus.

## Membaca hasil

DSR = U/(M*4)*100; SOURCE bukan target. LDR hanya DATA diterima, delay hanya
pasangan sukses, overhead DATA+CONTROL kelima ESP. CONTROL setup terpisah.
Kurva dihitung dari log setiap lima detik; bukan polling radio tambahan.
Jangan merata-ratakan overhead lintas window 180/420 detik.

`batch_complete`, `delivery_passed`, `core_checks_passed`, dan `mechanism_result`
berbeda. `passed` mensyaratkan sembilan SUCCESS, core checks PASS, tidak ada
kontradiksi validator, serta bukti repair S2 MPL PASS. FAILED_DELIVERY tetap
hasil sah. INCONCLUSIVE bukan PASS dan tidak otomatis membuat trial INVALID.

S2 MPL memerlukan stop timer DATA D (bukan CONTROL), buffer bertahan, tidak
ada restart sebelum E ON, serta CONTROL E -> MISSING -> reset -> native DATA
D -> RX E dengan identitas burst sama. Jadwal ON tidak digeser jika bukti
stop belum ada. Pengujian HP tetap diperlukan sebelum eksperimen utama.
