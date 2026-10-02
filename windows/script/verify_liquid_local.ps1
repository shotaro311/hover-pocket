param(
    [ValidateSet('Debug','Release')][string]$Configuration = 'Debug',
    [string[]]$Targets = @('ui','shell','display','settings','ui-model','weather','voice','timer','calendar'),
    [ValidateRange(1,900)][int]$TimeoutSeconds = 360
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$executable = Join-Path $repoRoot "windows\src\HoverPocket.Shell\bin\$Configuration\net10.0-windows10.0.22621.0\HoverPocket.Shell.exe"
$evidenceRoot = Join-Path $repoRoot 'progress\evidence\2026-10-02-windows-liquid'
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$results = @()
foreach ($target in $Targets) {
    $log = Join-Path $evidenceRoot "$($Configuration.ToLowerInvariant())-$target-$([DateTime]::UtcNow.ToString('HHmmss')).log"
    $env:HOVERPOCKET_VERIFY_LOG = $log
    $started = [DateTime]::UtcNow
    $process = Start-Process -FilePath $executable -ArgumentList '--verify',$target -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw "$target verifier timeout, PID $($process.Id) remains for diagnosis" }
    $results += [pscustomobject]@{ target=$target; exit_code=$process.ExitCode; elapsed_seconds=([DateTime]::UtcNow-$started).TotalSeconds; log=$log }
    Write-Output "$Configuration $target exit=$($process.ExitCode)"
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceRoot "$($Configuration.ToLowerInvariant())-results.json") -Encoding utf8
if (@($results | Where-Object exit_code -ne 0).Count -gt 0) { exit 1 }
