[CmdletBinding()]
param(
    [switch]$RunCodexReadOnlyProbe,
    [string]$Configuration = "Debug"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    Write-Host "`n==> $Label" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$solution = Join-Path $repoRoot "windows\HoverPocket.Windows.sln"
$project = Join-Path $repoRoot "windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj"
$uiRoot = Join-Path $repoRoot "windows\ui"
$phase0Probe = Join-Path $repoRoot "windows\script\phase0_codex_app_server_probe.ps1"

Set-Location $repoRoot
Write-Host "Repository: $repoRoot"
Write-Host "HEAD      : $(git rev-parse HEAD)"
Write-Host "Branch    : $(git branch --show-current)"

Invoke-Checked "Fetch remote refs" {
    git fetch origin --prune
}

Invoke-Checked "Patch whitespace" {
    git diff --check origin/main...HEAD
}

Invoke-Checked "Restore Windows solution" {
    dotnet restore $solution
}

Invoke-Checked "Build Debug with warnings as errors" {
    dotnet build $solution -c Debug --no-restore -p:TreatWarningsAsErrors=true
}

Invoke-Checked "Build Release with warnings as errors" {
    dotnet build $solution -c Release --no-restore -p:TreatWarningsAsErrors=true
}

Invoke-Checked "Windows UI JavaScript syntax" {
    $files = Get-ChildItem -Path $uiRoot -Recurse -File -Filter *.js
    if ($files.Count -eq 0) {
        throw "No JavaScript files were found under windows/ui."
    }

    foreach ($file in $files) {
        node --check $file.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "JavaScript syntax check failed: $($file.FullName)"
        }
    }

    Write-Host "Checked $($files.Count) JavaScript files."
}

$targets = @(
    "ui-model",
    "sticky",
    "calc",
    "timer",
    "calendar",
    "settings",
    "ailane",
    "voice-lane-layout",
    "codex-app-server-protocol",
    "codex-voice-coordinator",
    "updater"
)

foreach ($target in $targets) {
    Invoke-Checked "Verifier: $target" {
        $logPath = Join-Path $env:TEMP ("hoverpocket-verify-" + $target + "-" + [Guid]::NewGuid().ToString("N") + ".log")
        $env:HOVERPOCKET_VERIFY_LOG = $logPath
        try {
            dotnet run --project $project -c $Configuration --no-build -- --verify $target
            $exitCode = $LASTEXITCODE
            if (Test-Path $logPath) {
                Get-Content -Path $logPath
            }

            $global:LASTEXITCODE = $exitCode
        }
        finally {
            Remove-Item Env:HOVERPOCKET_VERIFY_LOG -ErrorAction SilentlyContinue
            Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Checked "Verifier exception exits instead of hanging" {
    $logPath = Join-Path $env:TEMP ("hoverpocket-verify-ui-model-failure-" + [Guid]::NewGuid().ToString("N") + ".log")
    $env:HOVERPOCKET_VERIFY_LOG = $logPath
    $env:HOVERPOCKET_VERIFY_INJECT_FAILURE = "ui-model"
    try {
        dotnet run --project $project -c $Configuration --no-build -- --verify ui-model
        $exitCode = $LASTEXITCODE
        $logText = (Test-Path $logPath) ? (Get-Content -Path $logPath -Raw) : ""
        if ($exitCode -ne 1 -or $logText -notmatch "FAIL verifier exception: InvalidOperationException") {
            throw "Injected verifier failure did not exit cleanly with code 1."
        }
        $global:LASTEXITCODE = 0
    }
    finally {
        Remove-Item Env:HOVERPOCKET_VERIFY_INJECT_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:HOVERPOCKET_VERIFY_LOG -ErrorAction SilentlyContinue
        Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
    }
}

if ($RunCodexReadOnlyProbe) {
    Invoke-Checked "Codex CLI version" {
        codex --version
    }

    Write-Host "`n==> Read-only Codex app-server Phase 0 probe" -ForegroundColor Cyan
    & $phase0Probe
    if ($LASTEXITCODE -ne 0) {
        throw "Phase 0 probe failed with exit code $LASTEXITCODE"
    }

    Invoke-Checked "Read-only installed Codex app-server verifier" {
        $logPath = Join-Path $env:TEMP ("hoverpocket-codex-app-server-" + [Guid]::NewGuid().ToString("N") + ".log")
        $env:HOVERPOCKET_VERIFY_LOG = $logPath
        try {
            dotnet run --project $project -c $Configuration --no-build -- --verify codex-app-server
            $exitCode = $LASTEXITCODE
            if (Test-Path $logPath) {
                Get-Content -Path $logPath
            }

            $global:LASTEXITCODE = $exitCode
        }
        finally {
            Remove-Item Env:HOVERPOCKET_VERIFY_LOG -ErrorAction SilentlyContinue
            Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "`nPASS: Voice Lane foundation verification completed." -ForegroundColor Green
