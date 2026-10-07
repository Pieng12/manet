$ErrorActionPreference = 'Stop'
$Script = Join-Path $PSScriptRoot 'build_neighbor.ps1'
$Tokens = $null
$Errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -gt 0) { throw ($Errors | Out-String) }
$First = & $Script -FingerprintOnly
$Second = & $Script -FingerprintOnly
if ($First.build_id -notmatch '^[a-f0-9]{12}$') { throw 'Build ID tidak valid' }
if ($First.source_sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Hash source tidak valid' }
if ($First.source_sha256 -ne $Second.source_sha256) { throw 'Hash source tidak stabil' }
if ($First.build_id -ne $First.source_sha256.Substring(0,12)) { throw 'Build ID tidak cocok' }
$Ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$Tokens, [ref]$Errors)
$Helper = $Ast.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-CheckedBuild' }, $true)
Invoke-Expression $Helper.Extent.Text
$Python = (Get-Command py).Source
$null = Invoke-CheckedBuild -Executable $Python -Arguments @('-c', 'import sys;sys.stderr.write(chr(119)*3+chr(10));sys.exit(0)') -FailureMessage 'mock warning' 2>&1
$Rejected = $false
try {
    $null = Invoke-CheckedBuild -Executable $Python -Arguments @('-c', 'import sys;sys.exit(7)') -FailureMessage 'mock failure'
} catch { $Rejected = $_.Exception.Message -match 'exit code 7' }
if (-not $Rejected) { throw 'Exit code build gagal tidak ditolak' }
Write-Output 'PASS: parse, stable fingerprint, ID/hash, native warning accepted, failing exit rejected; no build/flash'
