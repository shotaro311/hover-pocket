param([switch]$IncludeUi)
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
Push-Location $repository
try {
    dotnet run --project windows/tests/Assets.Sync
    if ($LASTEXITCODE -ne 0) { throw 'Asset sync checks failed' }
    dotnet run --project windows/tests/Assets.Core
    if ($LASTEXITCODE -ne 0) { throw 'Asset storage checks failed' }
    dotnet run --project windows/tests/Pairing
    if ($LASTEXITCODE -ne 0) { throw 'Device pairing checks failed' }
    node --check windows/ui/settings/settings-navigation.js
    if ($LASTEXITCODE -ne 0) { throw 'Settings navigation syntax failed' }
    node --check windows/ui/settings/asset-sync-settings.js
    if ($LASTEXITCODE -ne 0) { throw 'Settings script syntax failed' }
    if ($IncludeUi) {
        $output = Join-Path $repository 'artifacts\sync-verification-build'
        dotnet build windows/src/HoverPocket.Shell/HoverPocket.Shell.csproj -c Release -o $output -v:q
        if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
        $previous = $env:HOVERPOCKET_SYNC_VERIFY_ONLY
        try {
            $env:HOVERPOCKET_SYNC_VERIFY_ONLY = '1'
            & (Join-Path $output 'HoverPocket.Shell.exe') --verify ui
            if ($LASTEXITCODE -ne 0) { throw 'Settings WebView2 checks failed' }
        } finally { $env:HOVERPOCKET_SYNC_VERIFY_ONLY = $previous }
    }
} finally { Pop-Location }
