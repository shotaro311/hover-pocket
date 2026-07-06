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

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = "win-v$version"
}

$publishDir = Join-Path $outputRootPath "publish\$Runtime\$version"
$releaseDir = Join-Path $outputRootPath "releases\$version"
New-Item -ItemType Directory -Force -Path $publishDir, $releaseDir | Out-Null
$googleOAuthClientId = [string]$env:HOVERPOCKET_GOOGLE_CLIENT_ID
$googleOAuthClientSecret = [string]$env:HOVERPOCKET_GOOGLE_CLIENT_SECRET

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
