[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Project = (Join-Path $PSScriptRoot "..\src\HoverPocket.Shell\HoverPocket.Shell.csproj"),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\..\dist\windows"),
    [string]$PackId = "HoverPocketWin",
    [string]$PackTitle = "HoverPocket",
    [string]$PackAuthors = "Shotaro Matsumoto",
    [string]$ReleaseTag = "",
    [string]$VpkPath = "",
    [string]$NuGetSource = "",
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"

function Resolve-VpkPath {
    param([string]$Candidate)

    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        $resolved = Resolve-Path -LiteralPath $Candidate -ErrorAction Stop
        return $resolved.Path
    }

    $command = Get-Command vpk -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    throw "vpk CLI was not found. Install it with 'dotnet tool install -g vpk' or pass -VpkPath."
}

$projectPath = (Resolve-Path -LiteralPath $Project).Path
$outputRootPath = [System.IO.Path]::GetFullPath($OutputRoot)
$projectDirectory = Split-Path -Parent $projectPath
$projectXml = [xml](Get-Content -LiteralPath $projectPath -Raw)
$version = $projectXml.Project.PropertyGroup |
    ForEach-Object { $_.Version } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Version is missing from $projectPath."
}

if (-not [string]::Equals($Configuration, "Release", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Windows release packaging requires Configuration=Release."
}

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = "win-v$version"
}

if (-not [string]::Equals($ReleaseTag, "win-v$version", [System.StringComparison]::Ordinal)) {
    throw "ReleaseTag must match the project version: win-v$version."
}

$publishDir = Join-Path $outputRootPath "publish\$Runtime\$version"
$releaseDir = Join-Path $outputRootPath "releases\$version"
New-Item -ItemType Directory -Force -Path $publishDir, $releaseDir | Out-Null
$googleOAuthClientId = [string]$env:HOVERPOCKET_GOOGLE_CLIENT_ID
$googleOAuthClientSecret = [string]$env:HOVERPOCKET_GOOGLE_CLIENT_SECRET

if ([string]::IsNullOrWhiteSpace($googleOAuthClientId) -or
    [string]::IsNullOrWhiteSpace($googleOAuthClientSecret)) {
    throw "HOVERPOCKET_GOOGLE_CLIENT_ID and HOVERPOCKET_GOOGLE_CLIENT_SECRET are required for a Windows release."
}

$publishArgs = @(
    "publish",
    $projectPath,
    "--configuration", $Configuration,
    "--runtime", $Runtime,
    "--self-contained", "true",
    "--output", $publishDir,
    "-p:PublishSingleFile=false",
    "-p:Version=$version",
    "-p:GoogleOAuthClientId=$googleOAuthClientId",
    "-p:GoogleOAuthClientSecret=$googleOAuthClientSecret"
)

if ($NoRestore) {
    $publishArgs += "--no-restore"
}

if (-not [string]::IsNullOrWhiteSpace($NuGetSource)) {
    $publishArgs += @("--source", $NuGetSource, "--ignore-failed-sources")
}

Write-Host "Publishing HoverPocket Windows $version..."
Push-Location $projectDirectory
try {
    & dotnet @publishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$vpk = Resolve-VpkPath $VpkPath
$mainExe = "HoverPocket.Shell.exe"
$publishedExe = Join-Path $publishDir $mainExe
$previousExpectedVersion = [Environment]::GetEnvironmentVariable("HOVERPOCKET_RELEASE_EXPECTED_VERSION")
$env:HOVERPOCKET_RELEASE_EXPECTED_VERSION = $version
try {
    Write-Host "Verifying release configuration without printing OAuth values..."
    & $publishedExe --verify release-config
    if ($LASTEXITCODE -ne 0) {
        throw "release-config verification failed with exit code $LASTEXITCODE."
    }
}
finally {
    if ($null -eq $previousExpectedVersion) {
        Remove-Item Env:HOVERPOCKET_RELEASE_EXPECTED_VERSION -ErrorAction SilentlyContinue
    }
    else {
        $env:HOVERPOCKET_RELEASE_EXPECTED_VERSION = $previousExpectedVersion
    }
}

$packArgs = @(
    "pack",
    "--packId", $PackId,
    "--packVersion", $version,
    "--packDir", $publishDir,
    "--mainExe", $mainExe,
    "--outputDir", $releaseDir,
    "--channel", "win",
    "--runtime", $Runtime,
    "--packAuthors", $PackAuthors,
    "--packTitle", $PackTitle,
    "--delta", "None",
    "--yes",
    "--skip-updates"
)

Write-Host "Packing Velopack assets..."
& $vpk @packArgs
if ($LASTEXITCODE -ne 0) {
    throw "vpk pack failed with exit code $LASTEXITCODE."
}

$releaseManifestPath = Join-Path $releaseDir "release-manifest.win.json"
$releaseManifest = [ordered]@{
    schemaVersion = 1
    product = "HoverPocket"
    packageId = $PackId
    version = $version
    runtime = $Runtime
    updateChannel = "win"
    updateFeed = "releases.win.json"
    oauthMetadata = "embedded-and-verified"
    authenticode = "unsigned"
}
$releaseManifestJson = $releaseManifest | ConvertTo-Json
[System.IO.File]::WriteAllText(
    $releaseManifestPath,
    $releaseManifestJson,
    [System.Text.UTF8Encoding]::new($false))

$checksumPath = Join-Path $releaseDir "SHA256SUMS-win.txt"
$checksumLines = Get-ChildItem -LiteralPath $releaseDir -File |
    Where-Object { $_.Name -ne "SHA256SUMS-win.txt" } |
    Sort-Object Name |
    ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $($_.Name)"
    }
[System.IO.File]::WriteAllLines(
    $checksumPath,
    $checksumLines,
    [System.Text.Encoding]::ASCII)

$assets = Get-ChildItem -LiteralPath $releaseDir -File |
    Sort-Object Name |
    Select-Object Name, Length, FullName

Write-Host ""
Write-Host "Generated assets:"
$assets | Format-Table Name, Length -AutoSize

Write-Host ""
Write-Host "Upload is intentionally not executed by this script."
Write-Host "If a Windows GitHub Release does not exist yet, create it without changing GitHub Latest:"
Write-Host "gh release create $ReleaseTag --repo shotaro311/hover-pocket --title `"HoverPocket Windows $version`" --notes `"Windows Velopack release $version.`" --latest=false"
Write-Host ""
Write-Host "Upload only Windows Velopack assets to the Windows release:"
$assetArguments = $assets |
    ForEach-Object { '"' + $_.FullName + '"' }
Write-Host ("gh release upload $ReleaseTag " + ($assetArguments -join " ") + " --repo shotaro311/hover-pocket --clobber")
Write-Host ""
Write-Host "Read back the Windows feed and assets without using releases/latest:"
Write-Host "gh release view $ReleaseTag --repo shotaro311/hover-pocket --json tagName,assets,url"
Write-Host "Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/$ReleaseTag/releases.win.json"
Write-Host "Invoke-WebRequest -UseBasicParsing -Uri https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml"
