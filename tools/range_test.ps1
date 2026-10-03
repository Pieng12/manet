[CmdletBinding()]
param(
    [ValidateSet('Run','Collect')][string]$Phase = 'Run',
    [string]$Serial = 'fbde50b6',
    [string]$Port = 'COM11',
    [string]$OutputDir,
    [Nullable[double]]$SourceLatitude,
    [Nullable[double]]$SourceLongitude,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

function Quote-RangeShell([string]$Value) { return "'" + $Value.Replace("'", "'\''") + "'" }
function New-RangeWatch { return [System.Diagnostics.Stopwatch]::StartNew() }
function New-RangeSerialPort([string]$Name) { return [System.IO.Ports.SerialPort]::new($Name,115200) }
function Open-RangePort([string]$Name) {
    $connection = New-RangeSerialPort $Name
    $connection.ReadBufferSize=65536
    $connection.DtrEnable=$false;$connection.RtsEnable=$false;$connection.NewLine="`n"
    try { $connection.Open() } catch {
        $connection.Dispose()
        throw "Cannot open $Name. Close serial monitors/other terminals first. $($_.Exception.Message)"
    }
    return $connection
}

function Send-RangePhone([hashtable]$Data) {
    $Data['command_id'] = "range-$($Data.command)-$([guid]::NewGuid().ToString('N'))"
    $remote = @('am','broadcast','-a','id.ac.usu.resqmesh.RESEARCH_COMMAND','-n',
        'id.ac.usu.resqmesh/id.ac.usu.resqmesh.ResearchCommandReceiver')
    foreach ($entry in $Data.GetEnumerator()) {
        $type = '--es'
        if ($entry.Value -is [bool]) { $type = '--ez' }
        elseif ($entry.Value -is [int]) { $type = '--ei' }
        elseif ($entry.Value -is [long]) { $type = '--el' }
        elseif ($entry.Value -is [double]) { $type = '--ef' }
        $text = if ($entry.Value -is [double]) { $entry.Value.ToString('R', [Globalization.CultureInfo]::InvariantCulture) } else { [string]$entry.Value }
        $remote += @($type,[string]$entry.Key,$text)
    }
    $shell = (@($remote | ForEach-Object { Quote-RangeShell $_ }) -join ' ')
    $broadcast = & adb -s $Serial shell $shell
    if ($LASTEXITCODE -ne 0 -or ($broadcast -join "`n") -match '"accepted"\s*:\s*false') {
        throw 'ADB command rejected; check USB and application.'
    }
    $broadcast | Add-Content -LiteralPath (Join-Path $OutputDir 'phone_commands.txt') -Encoding UTF8
    $watch = New-RangeWatch
    while ($watch.Elapsed.TotalSeconds -lt 30) {
        if ($null -ne $Esp -and $Esp.IsOpen) { Read-RangeSerial | Out-Null }
        $lines = & adb -s $Serial logcat -d -s ResQMeshCommand:I
        foreach ($line in $lines) {
            if ($line -notmatch 'RESQMESH_CMD_RESULT (\{.*\})') { continue }
            try { $reply = $Matches[1] | ConvertFrom-Json } catch { continue }
            if ($reply.command_id -ne $Data.command_id -or $reply.accepted -eq $true -or $reply.state -eq 'PROCESSING') { continue }
            $line | Add-Content -LiteralPath (Join-Path $OutputDir 'phone_commands.txt') -Encoding UTF8
            if ($reply.ok -ne $true) { throw "Phone command failed: $($reply.error)" }
            return $reply
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Phone final response timeout: $($Data.command_id). Do not start another SOS."
}

function Read-RangeSerial {
    $chunk = $Esp.ReadExisting()
    if (-not $chunk) { return }
    Add-Content -LiteralPath (Join-Path $OutputDir 'esp_serial.txt') -Value $chunk -NoNewline -Encoding UTF8
    $script:RangeSerialBuffer += $chunk
    while (($index = $script:RangeSerialBuffer.IndexOf("`n")) -ge 0) {
        $line = $script:RangeSerialBuffer.Substring(0,$index).TrimEnd("`r")
        $script:RangeSerialBuffer = $script:RangeSerialBuffer.Substring($index+1)
        try { $value = $line | ConvertFrom-Json } catch { continue }
        if ($value.kind -eq 'event') { $script:RangeEvents.Add($value) }
        elseif ($value.kind -eq 'response') { $value }
    }
}

function Send-RangeEsp([hashtable]$Data) {
    if ($null -eq $Esp -or -not $Esp.IsOpen) { throw 'ESP port not open.' }
    $Data['command_id'] = "range-$($Data.command)-$([guid]::NewGuid().ToString('N'))"
    $Esp.WriteLine(($Data | ConvertTo-Json -Compress))
    $watch = New-RangeWatch
    while ($watch.Elapsed.TotalSeconds -lt 15) {
        foreach ($reply in @(Read-RangeSerial)) {
            if ($reply.command_id -ne $Data.command_id) { continue }
            if ($reply.ok -ne $true) { throw "ESP command failed: $($reply.error)" }
            return $reply
        }
        Start-Sleep -Milliseconds 50
    }
    throw "ESP response timeout: $($Data.command_id)."
}

function Assert-RangePhone($Phone, $Range) {
    if (@($Range.unfinished_trials).Count -gt 0) { throw 'An old trial is unfinished. Export/finalize it before this pilot.' }
    if ($Range.run.status -in @('prepared','running')) { throw 'An old range pilot is still active. Collect it before this pilot.' }
    if ($Phone.bluetooth -ne $true -or $Phone.scanner -ne $true -or $Phone.clock_valid -ne $true -or
        $Phone.permissions.scan -ne $true -or $Phone.radio.ready -ne $true -or
        $Phone.radio.scan_phy -ne 'coded' -or [string]::IsNullOrWhiteSpace($Phone.android_build_id) -or
        $Phone.android_build_id -eq 'unknown') { throw 'Phone build/scanner/clock/Coded readiness failed.' }
}

function Assert-RangeEspIdle($Ready) {
    if ($Ready.observation_window_open -eq $true -or $Ready.packet_pending -eq $true -or $Ready.advertising -eq $true) {
        throw 'An old ESP trial is active. Stop/finalize/archive it before this pilot; no reset performed.'
    }
}

function Assert-RangeEsp($Ready) {
    if ($Ready.radio.ready -ne $true -or $Ready.clock_valid -ne $true -or
        $Ready.radio.configured_mode -ne 'coded' -or $Ready.scanner -ne $true -or
        $Ready.radio.primary_phy -ne 'coded' -or $Ready.radio.secondary_phy -ne 'coded' -or
        $Ready.radio.advertising_interval_units -ne 400 -or
        $Ready.epoch_valid -ne $true -or
        [string]::IsNullOrWhiteSpace($Ready.firmware_build_id) -or $Ready.firmware_build_id -eq 'unknown') { throw 'ESP readiness failed.' }
}

function Assert-RangeStopped($Ready) {
    if ($Ready.advertising -ne $false -or $Ready.packet_pending -ne $false -or
        $Ready.observation_window_open -ne $false -or $Ready.quiet_period_complete -ne $true) {
        throw 'ESP shutdown NOT confirmed. Stop or power off ESP before returning with the phone.'
    }
}

function Save-RangeJson($Value,[string]$Name) {
    ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath (Join-Path $OutputDir $Name) -Encoding UTF8
}

function Get-RangeExport([string]$DevicePath,[string]$Name) {
    $raw = & adb -s $Serial exec-out run-as id.ac.usu.resqmesh cat $DevicePath
    if ($LASTEXITCODE -ne 0) { throw "Cannot collect $DevicePath. No reset performed." }
    $text = $raw -join "`n"
    if ($Name.EndsWith('.json')) { $text | ConvertFrom-Json | Out-Null }
    $text | Set-Content -LiteralPath (Join-Path $OutputDir $Name) -Encoding UTF8
}

if ($LibraryOnly) { return }
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
if ($Phase -eq 'Collect') {
    if (-not $OutputDir) { throw '-OutputDir of the existing pilot is required.' }
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
    $manifest = Get-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.kind -ne 'range_pilot_not_main_experiment') {
        throw 'Not a range pilot folder. No data changed.'
    }
    $status = Send-RangePhone @{command='get_range_test_status'}
    if ($status.run.run_id -ne $manifest.session_id -or $status.run.trial_id -ne $manifest.trial_id) { throw 'App pilot does not match the requested output. No state changed.' }
    $phone = Send-RangePhone @{command='readiness'}
    if (($phone.session_id -and $phone.session_id -ne $manifest.session_id) -or
        ($phone.trial_id -and $phone.trial_id -ne $manifest.trial_id)) {
        throw 'Another phone session/trial is active. No state changed; collect pilot before starting other experiments.'
    }
    Send-RangePhone @{command='configure_range_test';run_id=$manifest.session_id;action='finish'} | Out-Null
    if ($status.protocol_trial.status -eq 'RUNNING') {
        Send-RangePhone @{command='end_observation_window';trial_id=$manifest.trial_id} | Out-Null
    }
    $export = Send-RangePhone @{command='export_range_test'}
    Get-RangeExport $export.json_path 'range_trial.json'
    $range = Get-Content -LiteralPath (Join-Path $OutputDir 'range_trial.json') -Raw | ConvertFrom-Json
    $source = Get-Content -LiteralPath (Join-Path $OutputDir 'source_status.json') -Raw | ConvertFrom-Json
    $result = 'INVALID'
    if ($source.completed_duration -eq $true -and $source.stop_confirmed -eq $true -and $source.advertise_failed_count -eq 0) {
        $result = if (@($range.receives | Where-Object { $_.phase -eq 'session' }).Count -gt 0) { 'SUCCESS' } else { 'FAILED_DELIVERY' }
    }
    if ($null -eq $status.protocol_trial.finalized_at) {
        Send-RangePhone @{command='finalize_trial';trial_id=$manifest.trial_id;result=$result;reason='range_pilot_collected_not_a_maximum_range_measurement'} | Out-Null
    }
    $trial = Send-RangePhone @{command='export_trial';session_id=$manifest.session_id;trial_id=$manifest.trial_id}
    Get-RangeExport $trial.json_path 'android_trial.json'
    Get-RangeExport $trial.csv_path 'android_trial.csv'
    & py tools\experiment_controller\range_report.py --output $OutputDir
    if ($LASTEXITCODE -ne 0) { throw 'Workbook export failed. Raw data preserved; no reset performed.' }
    Send-RangePhone @{command='reset_trial';trial_id=$manifest.trial_id} | Out-Null
    Write-Host "Collected: $OutputDir\resqmesh_range_analysis.xlsx"
    return
}

if (($null -eq $SourceLatitude) -ne ($null -eq $SourceLongitude)) { throw 'Provide both source coordinates or neither.' }
$Session = 'coded-range-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$Trial = "$Session-T001"
if (-not $OutputDir) { $OutputDir = Join-Path $Root "experiment_output\$Session" }
if (Test-Path -LiteralPath $OutputDir) { throw 'Output directory exists. Use a new directory; nothing will be deleted.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$script:RangeSerialBuffer = ''
$script:RangeEvents = [System.Collections.Generic.List[object]]::new()
$Esp = $null
$sourceMayTransmit = $false
$sourceStatus = @{stop_confirmed=$false;completed_duration=$false;error=$null}
Save-RangeJson $sourceStatus 'source_status.json'
Write-Host "Pilot output: $OutputDir"
try {
    $phone = Send-RangePhone @{command='readiness'}
    $range = Send-RangePhone @{command='get_range_test_status'}
    Assert-RangePhone $phone $range
    Save-RangeJson $phone 'phone_before.json'
    $Esp = Open-RangePort $Port
    $beforeEsp = Send-RangeEsp @{command='readiness'}
    Assert-RangeEspIdle $beforeEsp
    Save-RangeJson $beforeEsp 'esp_original.json'
    Send-RangeEsp @{command='reset_trial'} | Out-Null
    Start-Sleep -Seconds 3
    Send-RangeEsp @{command='clock_sync';wall_time_ms=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()} | Out-Null
    Send-RangeEsp @{command='configure_session';node_id='esp-range-source';build_id='coded-range-pilot';
        session_id=$Session;role='SOURCE';mode='basic_flooding';hypothesis='H1';
        node_layer=0;expected_hop_in=0;hop_out=1;rx_burst_gap_ms=1000;protocol_active=$true;
        radio_mode='coded';protocol_version='resqmesh-ble17-v1';
        protocol_epoch_id='resqmesh-2026-06-01';protocol_epoch_seconds=1780272000} | Out-Null
    $espReady=Send-RangeEsp @{command='readiness'}
    Assert-RangeEsp $espReady
    Save-RangeJson $espReady 'esp_before.json'
    $manifest=@{session_id=$Session;trial_id=$Trial;duration_seconds=1200;point_seconds=60;
        android_build_id=$phone.android_build_id;esp_build_id=$espReady.firmware_build_id;
        tx_power_actual_dbm=$espReady.radio.tx_power_actual_dbm;kind='range_pilot_not_main_experiment'}
    Save-RangeJson $manifest 'manifest.json'
    Send-RangePhone @{command='configure_session';session_id=$Session;session_code='CODED-RANGE-PILOT';
        node_id='android-range-destination';role='DESTINATION';target_hop=1;hypothesis='H1';
        observation_window_ms=1500000;mode='basic_flooding';build_id=$phone.android_build_id;
        node_layer=1;expected_hop_in=1;hop_out=0;rx_burst_gap_ms=1000;radio_mode='coded'} | Out-Null
    Send-RangePhone @{command='start_trial';session_id=$Session;trial_id=$Trial;trial_code='H1-RANGE-PILOT'} | Out-Null
    Send-RangeEsp @{command='start_trial';trial_id=$Trial} | Out-Null
    $sourceMayTransmit=$true
    Send-RangeEsp @{command='trigger_sos';latitude=3.5952;longitude=98.6722} | Out-Null
    $sos = $script:RangeEvents | Where-Object { $_.event_type -eq 'SOS_CREATED' -and $_.trial_id -eq $Trial } | Select-Object -Last 1
    if ($null -eq $sos) { throw 'SOS_CREATED missing; do not re-trigger.' }
    $profile=@{command='configure_range_test';run_id=$Session;session_id=$Session;trial_id=$Trial;
        source_sender_crc=[long]$sos.sender_crc;source_timestamp_ms=[long]$sos.protocol_timestamp_ms}
    $manifest['source_sender_crc'] = [long]$sos.sender_crc
    $manifest['source_timestamp_ms'] = [long]$sos.protocol_timestamp_ms
    Save-RangeJson $manifest 'manifest.json'
    if ($null -ne $SourceLatitude) { $profile['source_latitude']=[double]$SourceLatitude;$profile['source_longitude']=[double]$SourceLongitude }
    Send-RangePhone $profile | Out-Null
    Write-Host 'Open Research Monitor > UJI JARAK. Mark ESP position while the phone is still connected.'
    $baseline=[System.Diagnostics.Stopwatch]::StartNew()
    do {
        Read-RangeSerial | Out-Null
        $status=Send-RangePhone @{command='get_range_test_status'}
        if ($status.baseline_received -eq $true -and $status.baseline_coded -eq $true -and $null -ne $status.run.source_latitude) { break }
        if ($baseline.Elapsed.TotalSeconds -gt 120) { throw 'Coded baseline or source position missing after 120s. Pilot aborted.' }
        Start-Sleep -Seconds 1
    } while ($true)
    $started=Send-RangePhone @{command='configure_range_test';run_id=$Session;action='start'}
    if ($started.status -ne 'running') { throw 'Range pilot did not enter running state.' }
    $manifest['run_start_phone_ms']=$started.started_at_ms
    $manifest['run_end_phone_ms']=$started.ends_at_ms
    Save-RangeJson $manifest 'manifest.json'
    Write-Host 'BASELINE PASSED. Unplug PHONE USB only. Leave ESP + laptop powered here. Sending for 20 minutes.'
    $watch=[System.Diagnostics.Stopwatch]::StartNew()
    $sourceStatus['started_at_utc_ms']=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    while ($watch.Elapsed.TotalSeconds -lt 1200) {
        Read-RangeSerial | Out-Null
        Start-Sleep -Milliseconds 100
    }
    $sourceStatus['completed_duration']=$true
} catch {
    $sourceStatus['error']=$_.Exception.Message
    throw
} finally {
    $sourceStatus['cleanup_at_utc_ms']=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($null -ne $Esp -and $Esp.IsOpen) {
        if ($sourceMayTransmit) {
            try {
                Send-RangeEsp @{command='end_observation_window'} | Out-Null
                Send-RangeEsp @{command='reset_trial'} | Out-Null
                Start-Sleep -Seconds 3
                $stopped=Send-RangeEsp @{command='readiness'}
                Assert-RangeStopped $stopped
                $sourceStatus['stop_confirmed']=$true
                $sourceStatus['final_readiness']=$stopped
            } catch {
                $sourceStatus['stop_error']=$_.Exception.Message
                Write-Warning 'ESP stop NOT confirmed. Power off ESP before bringing the phone back near it.'
            }
        }
        $Esp.Close();$Esp.Dispose()
    }
    $sourceStatus['advertise_failed_count'] = @($script:RangeEvents.ToArray() | Where-Object { $_.event_type -eq 'ADVERTISE_BURST_FAILED' }).Count
    $sourceStatus['advertise_started_count'] = @($script:RangeEvents.ToArray() | Where-Object { $_.event_type -eq 'ADVERTISE_BURST_STARTED' }).Count
    Save-RangeJson $sourceStatus 'source_status.json'
    Save-RangeJson @($script:RangeEvents.ToArray()) 'source_events.json'
    Write-Host "ESP stop confirmed: $($sourceStatus.stop_confirmed). Output: $OutputDir"
}
