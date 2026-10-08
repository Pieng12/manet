[CmdletBinding()]
param(
    [switch]$FingerprintOnly,
    [string]$Python = 'py',
    [string]$Flutter = 'flutter'
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Invoke-CheckedBuild {
    param([string]$Executable, [string[]]$Arguments, [string]$FailureMessage)
    $PreviousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell wraps native stderr warnings in non-terminating errors.
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments
        $ExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $PreviousPreference }
    if ($ExitCode -ne 0) { throw "$FailureMessage (exit code $ExitCode)" }
}

function Get-SourceFingerprint {
    $Paths = @('lib', 'android/app/src/main', 'android/app/src/debug',
        'android/app/build.gradle.kts', 'android/settings.gradle.kts',
        'android/build.gradle.kts', 'android/gradle.properties',
        'android/gradle/wrapper/gradle-wrapper.properties',
        'firmware/esp32c3/src', 'firmware/esp32c3/include',
        'firmware/esp32c3/platformio.ini', 'firmware/esp32c3/build_id.py',
        'tools/experiment_controller/resqmesh_controller',
        'tools/experiment_controller/requirements.txt', 'tools/build_neighbor.ps1',
        'pubspec.yaml', 'pubspec.lock')
    $Files = @(& git -C $Root ls-files --cached --others --exclude-standard -- $Paths |
        Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0 -or $Files.Count -eq 0) { throw 'Tidak dapat membaca daftar source Git' }
    $Lines = foreach ($File in $Files) {
        $Full = Join-Path $Root $File
        if (Test-Path -LiteralPath $Full -PathType Leaf) {
            $Hash = (Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant()
            "$File`:$Hash"
        }
    }
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))
        $Hex = [BitConverter]::ToString($Sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $Sha.Dispose() }
    return @{ build_id = $Hex.Substring(0, 12); source_sha256 = $Hex; files = @($Lines) }
}

Push-Location $Root
$OldBuildId = $env:RESQMESH_BUILD_ID
try {
    $Branch = (& git branch --show-current).Trim()
    if ($Branch -notin @('metode-penerimaan', 'MPL')) { throw "Branch salah: $Branch; gunakan metode-penerimaan atau MPL" }
    $Fingerprint = Get-SourceFingerprint
    if ($FingerprintOnly) {
        [pscustomobject]@{ build_id = $Fingerprint.build_id; source_sha256 = $Fingerprint.source_sha256 }
        return
    }
    $env:RESQMESH_BUILD_ID = $Fingerprint.build_id
    Invoke-CheckedBuild -Executable $Python -Arguments @('-m', 'platformio', 'run', '-d', 'firmware/esp32c3', '-e', 'esp32c3') -FailureMessage 'Build firmware gagal'
    Invoke-CheckedBuild -Executable $Flutter -Arguments @('build', 'apk', '--debug', '--dart-define=RESQMESH_MODE=offline', "--dart-define=RESQMESH_BUILD_ID=$env:RESQMESH_BUILD_ID") -FailureMessage 'Build APK gagal'
    if ((Get-SourceFingerprint).source_sha256 -ne $Fingerprint.source_sha256) {
        throw 'Source berubah saat build; jangan gunakan pasangan artifact ini'
    }
    $Archive = Join-Path $Root ("build/neighbor-{0}-{1}" -f $Fingerprint.build_id, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $null = New-Item -ItemType Directory -Path $Archive
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-debug.apk' -Destination $Archive
    Copy-Item -LiteralPath 'firmware/esp32c3/.pio/build/esp32c3/firmware.bin' -Destination $Archive
    foreach ($Name in @('bootloader.bin', 'partitions.bin', 'firmware.factory.bin')) {
        Copy-Item -LiteralPath (Join-Path 'firmware/esp32c3/.pio/build/esp32c3' $Name) -Destination $Archive
    }
    $Fingerprint.branch = $Branch
    $Fingerprint.git_reference = (& git rev-parse HEAD).Trim()
    $Fingerprint.created_at = [DateTimeOffset]::Now.ToString('o')
    $Fingerprint.description = 'SHA256 isi source, bukan klaim Git commit bersih; build saja, tanpa flash'
    $Fingerprint | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Archive 'build_manifest.json') -Encoding UTF8
    Write-Output "Build ID: $($Fingerprint.build_id)"
    Write-Output "Artifact: $Archive"
} finally {
    $env:RESQMESH_BUILD_ID = $OldBuildId
    Pop-Location
}
