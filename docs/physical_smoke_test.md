# Physical Testbed Windows

Dokumen ini adalah gerbang pengujian satu Android dan lima ESP32-C3. Unit test
dan CI tidak menggantikan bukti radio fisik.

## Topology

| Node | H1 | H2 | H3 |
|---|---|---|---|
| android-source | Source hop 1 | Source hop 1 | Source hop 1 |
| esp-r1a | Nonaktif | Relay 1 ke 2 | Relay 1 ke 2 |
| esp-r1b | Nonaktif | Relay 1 ke 2 | Relay 1 ke 2 |
| esp-r2a | Nonaktif | Nonaktif | Relay 2 ke 3 |
| esp-r2b | Nonaktif | Nonaktif | Relay 2 ke 3 |
| esp-destination | Destination hop 1 | Destination hop 2 | Destination hop 3 |

Pemisahan memakai role, `protocol_active`, `expected_hop_in`, dan `hop_out`,
bukan jarak. Seluruh ESP memakai firmware yang sama.

## Urutan Wajib

1. Periksa dependency.

   ```powershell
   flutter doctor -v
   adb version
   py --version
   py -m pip install -r tools/experiment_controller/requirements.txt
   ```

2. Build APK.

   ```powershell
   flutter pub get
   flutter build apk --debug --dart-define=RESQMESH_BUILD_ID=local-research
   ```

3. Instal APK.

   ```powershell
   adb devices -l
   adb install -r build/app/outputs/flutter-apk/app-debug.apk
   ```

4. Aktifkan Bluetooth, Nearby Devices scan/advertise, notifikasi, dan izin
   lokasi legacy jika Android memerlukannya.
5. Flash satu ESP32-C3 melalui native USB `303A:1001`.

   ```powershell
   cd firmware\esp32c3
   py -m platformio run -e esp32c3 -t upload --upload-port COM_YANG_BENAR
   cd ..\..
   ```

6. Uji command readiness serial satu baris. Respons tidak bergantung pada event
   `SERVICE_STARTED` atau serial monitor yang terus terbuka.

   ```json
   {"command":"readiness","command_id":"test-1"}
   ```

7. Flash empat ESP32-C3 lain dengan firmware yang sama.
8. Beri label fisik R1A, R1B, R2A, R2B, dan Destination.
9. Catat COM terbaru; nomor dapat berubah setelah upload.
10. Buat konfigurasi lokal.

    ```powershell
    Copy-Item tools/experiment_controller/config.example.json experiment.local.json
    ```

11. Jalankan discovery dan pastikan port Bluetooth serial tidak dipilih.

    ```powershell
    py tools/experiment_controller/run.py discover
    ```

12. Jalankan readiness.

    ```powershell
    py tools/experiment_controller/run.py readiness --config experiment.local.json
    ```

13. Jalankan smoke tepat enam kondisi.

    ```powershell
    py tools/experiment_controller/run.py smoke --config experiment.local.json --output experiment_output
    ```

14. Periksa `experiment_output/smoke_report.json` dan `.csv`. H2/H3 Trickle
    harus memiliki consistency relay sejajar dan minimal satu suppression;
    Basic tidak boleh memiliki suppression Trickle. Requested burst tanpa
    started callback tidak dihitung.
15. Jalankan batch hanya setelah smoke lulus.

    ```powershell
    py tools/experiment_controller/run.py run --config experiment.local.json --output experiment_output
    ```

16. Merge log dan pastikan setiap kombinasi memiliki 15 trial valid.

    ```powershell
    py tools/experiment_controller/run.py merge --input experiment_output/raw --manifest experiment_output/manifest.json --output experiment_output/merged
    Import-Csv experiment_output/merged/aggregate_by_mode_hop.csv | Format-Table
    ```

## Kriteria Smoke

- Semua node ready, clock dan epoch valid, queue/packet lama kosong.
- Source menghasilkan `SOURCE_FIRST_ADVERTISE_STARTED`.
- Destination menerima message key yang sama pada hop kondisi.
- E2E latency sinkron dan masuk akal.
- Reset, queue kosong, dan quiet period terverifikasi.
- `smoke_report.json` memiliki `passed=true` untuk enam kondisi.

Jika smoke gagal, controller keluar nonzero dan menyebut evidence yang hilang.
Batch menolak report yang gagal atau fingerprint-nya berbeda.

## Status

- `CODE VERIFIED`: ditentukan setelah seluruh test source lulus.
- `BUILD VERIFIED`: ditentukan setelah APK, native Android, dan firmware build.
- `DEVICE SERIAL VERIFIED`: pengguna telah membuktikan readiness native USB.
- `DEVICE SMOKE TEST NOT RUN`: masih berlaku sampai enam kondisi dijalankan.
- `PHYSICAL MULTI-HOP NOT RUN`: masih berlaku sampai H1-H3 dibuktikan fisik.
