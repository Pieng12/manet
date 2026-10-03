$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'range_test.ps1') -LibraryOnly
$OutputDir = Join-Path ([IO.Path]::GetTempPath()) ('range-script-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$script:Passed = 0
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Passed++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -match $Pattern) "expected $Pattern, received $_"
        return
    }
    throw "Expected rejection: $Pattern"
}

try {
    Check ((Quote-RangeShell 'rssi = -101, hop in 1') -eq "'rssi = -101, hop in 1'") 'spaces preserved'
    Check ((Quote-RangeShell "owner's pin") -eq "'owner'\''s pin'") 'apostrophe quoted'
    $phone = @{bluetooth=$true;scanner=$true;clock_valid=$true;permissions=@{scan=$true};
        radio=@{ready=$true;scan_phy='coded'};android_build_id='range-build'}
    Assert-RangePhone $phone @{unfinished_trials=@()}
    Reject { Assert-RangePhone $phone @{unfinished_trials=@(@{status='WINDOW_ENDED'})} } 'old trial'
    Reject { Assert-RangePhone $phone @{unfinished_trials=@();run=@{status='prepared'}} } 'old range pilot'
    Reject { Assert-RangeEspIdle @{observation_window_open=$true} } 'old ESP trial'
    Reject { Assert-RangeStopped @{advertising=$true;packet_pending=$false;observation_window_open=$false;quiet_period_complete=$true} } 'NOT confirmed'
    Assert-RangeStopped @{advertising=$false;packet_pending=$false;observation_window_open=$false;quiet_period_complete=$true}

    $script:Disposed = $false
    function New-RangeSerialPort {
        $port = [pscustomobject]@{ReadBufferSize=0;DtrEnable=$true;RtsEnable=$true;NewLine=''}
        $port | Add-Member ScriptMethod Open { throw 'Access to COM11 is denied' }
        $port | Add-Member ScriptMethod Dispose { $script:Disposed=$true }
        return $port
    }
    Reject { Open-RangePort 'COM11' } 'Cannot open COM11'
    Check $script:Disposed 'locked port resource disposed'

    $script:MockAdbFailure=$false
    function adb {
        if ($script:MockAdbFailure) { $global:LASTEXITCODE=1;return 'device disconnected' }
        $global:LASTEXITCODE=0
        if ($args[2] -eq 'shell') {
            $script:LastShell=$args[3]
            $script:LastId=[regex]::Match($args[3], "'command_id' '([^']+)'").Groups[1].Value
            return 'RESQMESH_CMD_RESULT {"accepted":true}'
        }
        return ('RESQMESH_CMD_RESULT ' + (@{command_id=$script:LastId;ok=$true;note='rssi = -101, hop in 1'} | ConvertTo-Json -Compress))
    }
    $Esp=$null
    $reply=Send-RangePhone @{command='readiness';reason='rssi = -101, hop in 1'}
    Check ($reply.ok -eq $true -and $script:LastShell.Contains("'rssi = -101, hop in 1'")) 'final response, correctly quoted note'
    $script:MockAdbFailure=$true
    Reject { Send-RangePhone @{command='readiness'} } 'ADB command rejected'
    $script:MockAdbFailure=$false
    function New-RangeWatch { return @{Elapsed=@{TotalSeconds=31}} }
    Reject { Send-RangePhone @{command='readiness'} } 'final response timeout'
    function New-RangeWatch { return [Diagnostics.Stopwatch]::StartNew() }

    $script:RangeSerialBuffer=''
    $script:RangeEvents=[Collections.Generic.List[object]]::new()
    $script:Chunk=''
    $Esp=[pscustomobject]@{IsOpen=$true}
    $Esp | Add-Member ScriptMethod WriteLine {
        param($line)
        $data=$line|ConvertFrom-Json
        $script:Chunk=(@{kind='response';command_id=$data.command_id;ok=$false;error='RADIO_FAILED'}|ConvertTo-Json -Compress)+"`n"
    }
    $Esp | Add-Member ScriptMethod ReadExisting {
        $value=$script:Chunk;$script:Chunk='';return $value
    }
    Reject { Send-RangeEsp @{command='trigger_sos'} } 'RADIO_FAILED'
    $script:Chunk='{"kind":"event","event_type":"ADVERTISE_BURST_STARTED"}'+"`n"
    Read-RangeSerial|Out-Null
    Check ($script:RangeEvents.Count -eq 1) 'serial still collected without phone USB'
    $script:Chunk='{"kind":"event","event_type":"ADVERTISE_'
    Read-RangeSerial|Out-Null
    $script:Chunk='BURST_ENDED"}'+"`n"
    Read-RangeSerial|Out-Null
    Check ($script:RangeEvents.Count -eq 2) 'fragmented serial lines preserved'

    $source=Get-Content (Join-Path $PSScriptRoot 'range_test.ps1') -Raw
    $sendLoop=[regex]::Match($source,'(?s)while \(\$watch.Elapsed.TotalSeconds -lt 1200\) \{(.*?)\}').Groups[1].Value
    Check ($sendLoop.Contains('Read-RangeSerial') -and $sendLoop -notmatch 'adb|Send-RangePhone') '20-minute loop independent of ADB'
    Check ($source.Contains('finally {') -and $source.Contains('Assert-RangeStopped $stopped')) 'cleanup requires stop confirmation'
    $tokens=$null;$parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'range_test.ps1'),[ref]$tokens,[ref]$parseErrors)|Out-Null
    Check ($parseErrors.Count -eq 0) 'PowerShell syntax'
    Save-RangeJson @() 'empty.json'
    Check (((Get-Content -LiteralPath (Join-Path $OutputDir 'empty.json') -Raw) -replace '\s','') -eq '[]') 'empty serial array retains JSON shape'
    Write-Host "PASS: $script:Passed range script checks (mocked devices; no hardware modified)."
} finally {
    $target = [IO.Path]::GetFullPath($OutputDir)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $target.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $target -Leaf) -notlike 'range-script-test-*') { throw 'Unsafe temporary cleanup path' }
    Remove-Item -LiteralPath $target -Recurse -Force
}
