# ResQMesh Experiment Controller

Controller mengatur Android melalui ADB dan ESP32-C3 melalui serial JSON. Ia
menyimpan `manifest.json` secara atomik sehingga proses dapat dilanjutkan tanpa
memicu ulang trial yang sudah terminal.

## Persiapan

```powershell
py -m pip install -r tools/experiment_controller/requirements.txt
Copy-Item tools/experiment_controller/config.example.json experiment.local.json
py tools/experiment_controller/run.py discover
```

Isi serial ADB, port COM, dan build ID yang sama pada `experiment.local.json`.
Konfigurasi contoh menghasilkan matrix 2 mode x H1/H2/H3 x 15 trial = 90
trial valid, tetapi batch penuh tidak boleh dijalankan sebelum smoke test.

## Perintah

```powershell
py tools/experiment_controller/run.py readiness --config experiment.local.json
py tools/experiment_controller/run.py smoke --config experiment.local.json --output experiment_output
py tools/experiment_controller/run.py run --config experiment.local.json --output experiment_output
py tools/experiment_controller/run.py merge --input experiment_output/raw --manifest experiment_output/manifest.json --output experiment_output/merged
```

`smoke` menjalankan satu trial untuk setiap kombinasi mode dan H1/H2/H3.
Controller menolak trial bila readiness atau epoch berbeda, menyinkronkan clock,
memastikan tepat satu source, mengumpulkan log setiap node, menentukan
`SUCCESS`, `FAILED_DELIVERY`, atau `INVALID`, mengekspor Android, mereset node,
dan menunggu quiet period.

Output merger:

- `events.json` dan `events.csv`
- `trial_summary.csv`
- `aggregate_by_mode_hop.csv`
- `invalid_trials.csv`

Event dideduplikasi memakai `node_id + event_key`, observation identity, atau
`node_id + burst_id + event_type`. Agregat menyediakan DSR, LDR, network-wide
transmission overhead, dan statistik E2E count/min/max/mean/median/sample
standard deviation/Q1/Q3/IQR.

## Test Tanpa Perangkat

```powershell
$env:PYTHONPATH='tools/experiment_controller'
py -m unittest discover -s tools/experiment_controller/tests -v
```
