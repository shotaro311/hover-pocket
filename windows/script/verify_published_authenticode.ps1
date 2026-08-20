[CmdletBinding()]
param(
    [string]$Repository = "shotaro311/hover-pocket",
    [string]$Tag = "auto"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-GitHubHeaders {
    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "HoverPocket-release-readback/1"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($token) {
        $headers.Authorization = "Bearer $token"
    }
    return $headers
}

function Resolve-WindowsRelease {
    param([string]$RequestedTag)

    $headers = Get-GitHubHeaders
    if ($RequestedTag -ne "auto") {
        if ($RequestedTag -notmatch '^win-v\d+\.\d+\.\d+$') {
            throw "Windows release tag must match win-vMAJOR.MINOR.PATCH."
        }
        $encoded = [Uri]::EscapeDataString($RequestedTag)
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/tags/$encoded"
    }

    $releases = @()
    for ($page = 1; $page -le 10; $page++) {
        $batch = @(Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page")
        $releases += $batch
        if ($batch.Count -lt 100) { break }
        if ($page -eq 10) { throw "Release history exceeds supported pagination." }
    }
    $candidates = @($releases | Where-Object {
        -not $_.draft -and $_.tag_name -match '^win-v(\d+)\.(\d+)\.(\d+)$'
    } | ForEach-Object {
        [pscustomobject]@{
            Version = [version]($_.tag_name.Substring(5))
            Release = $_
        }
    })
    if ($candidates.Count -eq 0) {
        throw "No published Windows release was found."
    }
    return ($candidates | Sort-Object Version -Descending | Select-Object -First 1).Release
}

function Get-ReleaseAsset {
    param($Release, [string]$Name, [string]$Destination)

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Release asset name is unsafe."
    }
    $matches = @($Release.assets | Where-Object { $_.name -eq $Name })
    if ($matches.Count -ne 1) {
        throw "Release asset $Name is missing or duplicated."
    }
    $uri = [Uri]$matches[0].browser_download_url
    $expectedPrefix = "/$Repository/releases/download/$($Release.tag_name)/"
    if ($uri.Scheme -ne "https" -or $uri.Host -ne "github.com" -or -not $uri.AbsolutePath.StartsWith($expectedPrefix)) {
        throw "Release asset $Name has an unexpected download URL."
    }
    Invoke-WebRequest -Headers @{ "User-Agent" = "HoverPocket-release-readback/1" } -Uri $uri -OutFile $Destination
}

function Expand-PortableArchiveSafely {
    param([string]$ArchivePath, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        [long]$totalLength = 0
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Portable ZIP contains a path outside its extraction root."
            }
            $totalLength += $entry.Length
            if ($entry.Length -gt 536870912 -or $totalLength -gt 1073741824) {
                throw "Portable ZIP exceeds extraction limits."
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination
}

function Read-Checksums {
    param([string]$Path)

    $result = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::ASCII)) {
        if (-not $line) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})  ([^/\\]+)$') {
            throw "Checksum file contains a malformed line."
        }
        if ($result.ContainsKey($Matches[2])) {
            throw "Checksum file contains a duplicate asset."
        }
        $result[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }
    return $result
}

function Assert-DownloadedChecksum {
    param([string]$Path, [string]$Name, [hashtable]$Checksums)

    if (-not $Checksums.ContainsKey($Name)) {
        throw "Checksum file does not cover $Name."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Checksums[$Name]) {
        throw "Downloaded checksum differs for $Name."
    }
}

function Assert-TimestampedAuthenticode {
    param([string]$Path, [string]$Label)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "$Label Authenticode status is $($signature.Status)."
    }
    if ($null -eq $signature.SignerCertificate -or $null -eq $signature.TimeStamperCertificate) {
        throw "$Label is not signed with a timestamped Authenticode signature."
    }
    return $signature
}

$release = Resolve-WindowsRelease -RequestedTag $Tag
$releaseTag = [string]$release.tag_name
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("hoverpocket-authenticode-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

try {
    $manifestPath = Join-Path $temporaryRoot "release-manifest.win.json"
    $checksumPath = Join-Path $temporaryRoot "SHA256SUMS-win.txt"
    Get-ReleaseAsset -Release $release -Name "release-manifest.win.json" -Destination $manifestPath
    Get-ReleaseAsset -Release $release -Name "SHA256SUMS-win.txt" -Destination $checksumPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.authenticode -ne "signed-timestamped-verified") {
        throw "Release manifest is not marked signed-timestamped-verified."
    }
    if ($releaseTag -ne "win-v$($manifest.version)") {
        throw "Release tag and manifest version differ."
    }

    $setupAsset = @($release.assets | Where-Object { $_.name -like '*-Setup.exe' })
    $portableAsset = @($release.assets | Where-Object { $_.name -like '*-Portable.zip' })
    if ($setupAsset.Count -ne 1 -or $portableAsset.Count -ne 1) {
        throw "Release must contain exactly one Setup executable and one Portable ZIP."
    }
    $setupPath = Join-Path $temporaryRoot $setupAsset[0].name
    $portablePath = Join-Path $temporaryRoot $portableAsset[0].name
    Get-ReleaseAsset -Release $release -Name $setupAsset[0].name -Destination $setupPath
    Get-ReleaseAsset -Release $release -Name $portableAsset[0].name -Destination $portablePath

    $checksums = Read-Checksums -Path $checksumPath
    Assert-DownloadedChecksum -Path $setupPath -Name $setupAsset[0].name -Checksums $checksums
    Assert-DownloadedChecksum -Path $portablePath -Name $portableAsset[0].name -Checksums $checksums
    $setupSignature = Assert-TimestampedAuthenticode -Path $setupPath -Label "Setup"

    $extractPath = Join-Path $temporaryRoot "portable"
    Expand-PortableArchiveSafely -ArchivePath $portablePath -Destination $extractPath
    $mainExecutables = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "HoverPocket.Shell.exe")
    if ($mainExecutables.Count -ne 1) {
        throw "Portable ZIP does not contain exactly one HoverPocket.Shell.exe."
    }
    $mainSignature = Assert-TimestampedAuthenticode -Path $mainExecutables[0].FullName -Label "HoverPocket.Shell.exe"
    if ($setupSignature.SignerCertificate.Thumbprint -ne $mainSignature.SignerCertificate.Thumbprint) {
        throw "Setup and application are signed by different certificates."
    }

    [ordered]@{
        status = "passed"
        releaseTag = $releaseTag
        setup = "signed-timestamped-verified"
        application = "signed-timestamped-verified"
        signerAgreement = "verified"
    } | ConvertTo-Json -Compress
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}
