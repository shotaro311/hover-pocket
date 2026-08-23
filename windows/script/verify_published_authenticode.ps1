[CmdletBinding()]
param(
    [string]$Repository = "shotaro311/hover-pocket",
    [string]$Tag = "auto",
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSnapshotPath,
    [switch]$IdentityOnly
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
        $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/tags/$encoded"
        if ($release.draft -or $release.prerelease) {
            throw "Windows release must be published and must not be a prerelease."
        }
        return $release
    }

    $releases = @()
    for ($page = 1; $page -le 10; $page++) {
        $batch = @(Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page")
        $releases += $batch
        if ($batch.Count -lt 100) { break }
        if ($page -eq 10) { throw "Release history exceeds supported pagination." }
    }
    $candidates = @($releases | Where-Object {
        -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^win-v(\d+)\.(\d+)\.(\d+)$'
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

function Expand-ZipArchiveSafely {
    param([string]$ArchivePath, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        [long]$totalLength = 0
        [int]$entryCount = 0
        $validatedEntries = [Collections.Generic.List[object]]::new()
        $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $entryCount++
            if ($entryCount -gt 10000) {
                throw "Archive contains too many entries."
            }
            $entryName = ([string]$entry.FullName).Replace('\', '/')
            $segments = @($entryName.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
            if (
                [string]::IsNullOrWhiteSpace($entryName) -or
                $segments.Count -eq 0 -or
                @($segments | Where-Object { $_ -in @('.', '..') -or $_.Contains(':') }).Count -ne 0
            ) {
                throw "Archive contains an unsafe entry name."
            }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive contains a path outside its extraction root."
            }
            if (-not $seenTargets.Add($target)) {
                throw "Archive contains duplicate or case-colliding entries."
            }
            $totalLength += $entry.Length
            if ($entry.Length -gt 536870912 -or $totalLength -gt 1073741824) {
                throw "Archive exceeds extraction limits."
            }
            $isDirectory = [string]::IsNullOrEmpty($entry.Name)
            if ($isDirectory -and $entry.Length -ne 0) {
                throw "Archive contains a malformed directory entry."
            }
            $validatedEntries.Add([pscustomobject]@{
                    Entry = $entry
                    Target = $target
                    IsDirectory = $isDirectory
                })
        }

        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        foreach ($item in $validatedEntries) {
            if ($item.IsDirectory) {
                [IO.Directory]::CreateDirectory($item.Target) | Out-Null
                continue
            }
            $parent = [IO.Path]::GetDirectoryName($item.Target)
            if ([string]::IsNullOrEmpty($parent)) {
                throw "Archive entry has no extraction parent."
            }
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            $inputStream = $item.Entry.Open()
            try {
                $outputStream = [IO.File]::Open($item.Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $inputStream.CopyTo($outputStream)
                    if ($outputStream.Length -ne $item.Entry.Length) {
                        throw "Archive entry length changed during extraction."
                    }
                }
                finally {
                    $outputStream.Dispose()
                }
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-NupkgReleaseIdentity {
    param(
        [string]$PackageRoot,
        [string]$ExpectedPackageId,
        [string]$ExpectedVersion,
        [string]$ExpectedChannel,
        [string]$ExpectedRuntime,
        [string]$Label
    )

    $nuspecFiles = @([IO.Directory]::EnumerateFiles(
            $PackageRoot,
            "*.nuspec",
            [IO.SearchOption]::TopDirectoryOnly
        ))
    $expectedNuspecName = "$ExpectedPackageId.nuspec"
    if (
        $nuspecFiles.Count -ne 1 -or
        [IO.Path]::GetFileName($nuspecFiles[0]) -cne $expectedNuspecName
    ) {
        throw "$Label must contain exactly one root $expectedNuspecName."
    }
    [xml]$nuspec = Get-Content -LiteralPath $nuspecFiles[0] -Raw
    $metadata = $nuspec.SelectSingleNode("/*[local-name()='package']/*[local-name()='metadata']")
    if ($null -eq $metadata) {
        throw "Full update package nuspec metadata is missing."
    }
    $identity = @{}
    foreach ($name in @("id", "version", "mainExe", "channel", "rid")) {
        $nodes = @($metadata.SelectNodes("*[local-name()='$name']"))
        if ($nodes.Count -ne 1 -or [string]::IsNullOrWhiteSpace($nodes[0].InnerText)) {
            throw "Full update package nuspec $name is missing or duplicated."
        }
        $identity[$name] = $nodes[0].InnerText.Trim()
    }
    if (
        $identity.id -cne $ExpectedPackageId -or
        $identity.version -cne $ExpectedVersion -or
        $identity.mainExe -cne "HoverPocket.Shell.exe" -or
        $identity.channel -cne $ExpectedChannel -or
        $identity.rid -cne $ExpectedRuntime
    ) {
        throw "Full update package embedded identity differs from the release manifest."
    }
}

function Assert-ExecutableReleaseVersion {
    param([string]$Path, [string]$ExpectedVersion, [string]$Label)

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $expected = [Version]$ExpectedVersion
    $fileVersion = [Version]$versionInfo.FileVersion
    if (
        $fileVersion.Major -ne $expected.Major -or
        $fileVersion.Minor -ne $expected.Minor -or
        $fileVersion.Build -ne $expected.Build
    ) {
        throw "$Label file version differs from the release manifest."
    }
    $productVersion = [string]$versionInfo.ProductVersion
    if ($productVersion -notmatch ('^' + [Regex]::Escape($ExpectedVersion) + '(?:$|[+ -])')) {
        throw "$Label product version differs from the release manifest."
    }
}

function Assert-AssemblyReleaseVersion {
    param([string]$PackageRoot, [string]$ExpectedVersion)

    $assemblies = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Filter "HoverPocket.Shell.dll")
    if ($assemblies.Count -ne 1) {
        throw "Full update package must contain exactly one HoverPocket.Shell.dll."
    }
    $actual = [Reflection.AssemblyName]::GetAssemblyName($assemblies[0].FullName).Version
    $expected = [Version]$ExpectedVersion
    if (
        $actual.Major -ne $expected.Major -or
        $actual.Minor -ne $expected.Minor -or
        $actual.Build -ne $expected.Build
    ) {
        throw "Full update package assembly version differs from the release manifest."
    }
}

function Assert-SetupEmbedsFullPackage {
    param([string]$SetupPath, [string]$PackagePath)

    $setupStream = [IO.File]::OpenRead($SetupPath)
    $packageStream = [IO.File]::OpenRead($PackagePath)
    try {
        if ($setupStream.Length -le $packageStream.Length) {
            throw "Setup does not contain an executable prefix before the full update package."
        }
        $payloadOffset = $setupStream.Length - $packageStream.Length
        if ($setupStream.Seek($payloadOffset, [IO.SeekOrigin]::Begin) -ne $payloadOffset) {
            throw "Setup embedded package offset could not be reached."
        }
        $setupHashAlgorithm = [Security.Cryptography.SHA256]::Create()
        $packageHashAlgorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $setupPayloadHash = [Convert]::ToHexString($setupHashAlgorithm.ComputeHash($setupStream))
            $packageHash = [Convert]::ToHexString($packageHashAlgorithm.ComputeHash($packageStream))
        }
        finally {
            $setupHashAlgorithm.Dispose()
            $packageHashAlgorithm.Dispose()
        }
        if ($setupPayloadHash -cne $packageHash) {
            throw "Setup embedded payload differs from the published full update package."
        }
    }
    finally {
        $setupStream.Dispose()
        $packageStream.Dispose()
    }
}

function Assert-PortablePayloadMatchesFullPackage {
    param([string]$PortableRoot, [string]$PackageRoot)

    $expectedPortableRoot = @{
        ".portable" = "file"
        "HoverPocket.exe" = "file"
        "Update.exe" = "file"
        "current" = "directory"
    }
    $portableRootItems = @(Get-ChildItem -LiteralPath $PortableRoot -Force)
    if ($portableRootItems.Count -ne $expectedPortableRoot.Count) {
        throw "Portable ZIP root layout differs from the canonical package."
    }
    foreach ($item in $portableRootItems) {
        if (-not $expectedPortableRoot.ContainsKey($item.Name)) {
            throw "Portable ZIP root contains an unexpected entry."
        }
        $expectedType = $expectedPortableRoot[$item.Name]
        if (
            ($expectedType -eq "directory" -and -not $item.PSIsContainer) -or
            ($expectedType -eq "file" -and $item.PSIsContainer)
        ) {
            throw "Portable ZIP root entry type differs from the canonical package."
        }
    }

    $portableApplicationRoot = Join-Path $PortableRoot "current"
    $packageApplicationRoot = Join-Path $PackageRoot "lib/app"
    $packageOnlyFiles = @("HoverPocket.Shell_ExecutionStub.exe", "Squirrel.exe")
    foreach ($name in $packageOnlyFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageApplicationRoot $name) -PathType Leaf)) {
            throw "Full update package is missing an expected package-only file."
        }
    }

    $portableFiles = @(Get-ChildItem -LiteralPath $portableApplicationRoot -Recurse -File -Force | ForEach-Object {
        [pscustomobject]@{
            Name = [IO.Path]::GetRelativePath($portableApplicationRoot, $_.FullName).Replace('\', '/')
            Size = $_.Length
            Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } | Sort-Object Name)
    $packageFiles = @(Get-ChildItem -LiteralPath $packageApplicationRoot -Recurse -File -Force | ForEach-Object {
        $relativeName = [IO.Path]::GetRelativePath($packageApplicationRoot, $_.FullName).Replace('\', '/')
        if ($relativeName -cnotin $packageOnlyFiles) {
            [pscustomobject]@{
                Name = $relativeName
                Size = $_.Length
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    } | Sort-Object Name)
    if ($portableFiles.Count -eq 0 -or $portableFiles.Count -ne $packageFiles.Count) {
        throw "Portable application and full update package contain different file sets."
    }
    for ($index = 0; $index -lt $portableFiles.Count; $index++) {
        if (
            $portableFiles[$index].Name -cne $packageFiles[$index].Name -or
            $portableFiles[$index].Size -ne $packageFiles[$index].Size -or
            $portableFiles[$index].Sha256 -cne $packageFiles[$index].Sha256
        ) {
            throw "Portable application payload differs from the full update package."
        }
    }
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

function Read-ExpectedSnapshot {
    param([string]$Path, [string]$ExpectedTag)

    if (-not [IO.File]::Exists($Path)) {
        throw "Expected asset snapshot is missing."
    }
    try {
        $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Expected asset snapshot is malformed."
    }
    $snapshot = $report.windows.assetSnapshot
    if ($report.status -ne "passed" -or $null -eq $snapshot -or $snapshot.releaseTag -cne $ExpectedTag) {
        throw "Expected asset snapshot does not describe the verified release."
    }
    $result = @{}
    foreach ($item in @($snapshot.assets)) {
        $name = [string]$item.name
        $sha256 = ([string]$item.sha256).ToLowerInvariant()
        [long]$size = 0
        if (
            $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            $sha256 -notmatch '^[0-9a-f]{64}$' -or
            -not [long]::TryParse(([string]$item.size), [ref]$size) -or
            $size -lt 0 -or
            $result.ContainsKey($name)
        ) {
            throw "Expected asset snapshot contains an invalid or duplicate entry."
        }
        $result[$name] = [pscustomobject]@{ Size = $size; SHA256 = $sha256 }
    }
    if ($result.Count -eq 0) {
        throw "Expected asset snapshot is empty."
    }
    return $result
}

function Assert-ReleaseMatchesSnapshot {
    param($Release, [hashtable]$ExpectedAssets)

    $releaseAssets = @($Release.assets)
    if ($releaseAssets.Count -ne $ExpectedAssets.Count) {
        throw "Published release asset count differs from the verified snapshot."
    }
    foreach ($name in $ExpectedAssets.Keys) {
        $matches = @($releaseAssets | Where-Object { $_.name -ceq $name })
        $expected = $ExpectedAssets[$name]
        if ($matches.Count -ne 1) {
            throw "Published release asset $name differs from the verified snapshot."
        }
        $digest = [string]$matches[0].digest
        if (
            [long]$matches[0].size -ne $expected.Size -or
            $digest -cne ("sha256:" + $expected.SHA256)
        ) {
            throw "Published release metadata for $name differs from the verified snapshot."
        }
    }
}

function Assert-DownloadedSnapshot {
    param([string]$Path, [string]$Name, [hashtable]$ExpectedAssets)

    if (-not $ExpectedAssets.ContainsKey($Name)) {
        throw "Verified snapshot does not cover $Name."
    }
    $expected = $ExpectedAssets[$Name]
    $file = Get-Item -LiteralPath $Path
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($file.Length -ne $expected.Size -or $actual -ne $expected.SHA256) {
        throw "Downloaded asset $Name differs from the verified snapshot."
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
$expectedAssets = Read-ExpectedSnapshot -Path $ExpectedSnapshotPath -ExpectedTag $releaseTag
Assert-ReleaseMatchesSnapshot -Release $release -ExpectedAssets $expectedAssets
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("hoverpocket-authenticode-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

try {
    $manifestPath = Join-Path $temporaryRoot "release-manifest.win.json"
    $checksumPath = Join-Path $temporaryRoot "SHA256SUMS-win.txt"
    $feedPath = Join-Path $temporaryRoot "releases.win.json"
    $releasesPath = Join-Path $temporaryRoot "RELEASES"
    $assetsPath = Join-Path $temporaryRoot "assets.win.json"
    Get-ReleaseAsset -Release $release -Name "release-manifest.win.json" -Destination $manifestPath
    Get-ReleaseAsset -Release $release -Name "SHA256SUMS-win.txt" -Destination $checksumPath
    Get-ReleaseAsset -Release $release -Name "releases.win.json" -Destination $feedPath
    Get-ReleaseAsset -Release $release -Name "RELEASES" -Destination $releasesPath
    Get-ReleaseAsset -Release $release -Name "assets.win.json" -Destination $assetsPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $feed = Get-Content -LiteralPath $feedPath -Raw | ConvertFrom-Json
    if ($IdentityOnly) {
        if ($manifest.authenticode -notin @("unsigned", "signed-timestamped-verified")) {
            throw "Release manifest contains an unknown Authenticode state."
        }
    }
    elseif ($manifest.authenticode -ne "signed-timestamped-verified") {
        throw "Release manifest is not marked signed-timestamped-verified."
    }
    if ($releaseTag -ne "win-v$($manifest.version)") {
        throw "Release tag and manifest version differ."
    }

    $setupAsset = @($release.assets | Where-Object { $_.name -ceq 'HoverPocketWin-win-Setup.exe' })
    $portableAsset = @($release.assets | Where-Object { $_.name -ceq 'HoverPocketWin-win-Portable.zip' })
    $fullPackages = @($feed.Assets | Where-Object { $_.Type -eq 'Full' })
    if ($setupAsset.Count -ne 1 -or $portableAsset.Count -ne 1 -or $fullPackages.Count -ne 1) {
        throw "Release must contain exactly one Setup executable, Portable ZIP, and full update package."
    }
    if ($fullPackages[0].Version -ne $manifest.version) {
        throw "Full update package and manifest versions differ."
    }
    $packageName = [string]$fullPackages[0].FileName
    $packageAsset = @($release.assets | Where-Object { $_.name -eq $packageName })
    if ($packageAsset.Count -ne 1 -or $packageName -notlike '*-full.nupkg') {
        throw "Feed full update package is missing, duplicated, or has an unexpected name."
    }
    $setupPath = Join-Path $temporaryRoot $setupAsset[0].name
    $portablePath = Join-Path $temporaryRoot $portableAsset[0].name
    $packagePath = Join-Path $temporaryRoot $packageName
    Get-ReleaseAsset -Release $release -Name $setupAsset[0].name -Destination $setupPath
    Get-ReleaseAsset -Release $release -Name $portableAsset[0].name -Destination $portablePath
    Get-ReleaseAsset -Release $release -Name $packageName -Destination $packagePath

    $checksums = Read-Checksums -Path $checksumPath
    Assert-DownloadedChecksum -Path $manifestPath -Name "release-manifest.win.json" -Checksums $checksums
    Assert-DownloadedChecksum -Path $feedPath -Name "releases.win.json" -Checksums $checksums
    Assert-DownloadedChecksum -Path $releasesPath -Name "RELEASES" -Checksums $checksums
    Assert-DownloadedChecksum -Path $assetsPath -Name "assets.win.json" -Checksums $checksums
    Assert-DownloadedChecksum -Path $setupPath -Name $setupAsset[0].name -Checksums $checksums
    Assert-DownloadedChecksum -Path $portablePath -Name $portableAsset[0].name -Checksums $checksums
    Assert-DownloadedChecksum -Path $packagePath -Name $packageName -Checksums $checksums
    $downloadedPaths = @{
        "release-manifest.win.json" = $manifestPath
        "SHA256SUMS-win.txt" = $checksumPath
        "releases.win.json" = $feedPath
        "RELEASES" = $releasesPath
        "assets.win.json" = $assetsPath
    }
    $downloadedPaths[[string]$setupAsset[0].name] = $setupPath
    $downloadedPaths[[string]$portableAsset[0].name] = $portablePath
    $downloadedPaths[$packageName] = $packagePath
    if ($downloadedPaths.Count -ne $expectedAssets.Count) {
        throw "Formal readback did not download every asset from the verified snapshot."
    }
    foreach ($entry in $downloadedPaths.GetEnumerator()) {
        Assert-DownloadedSnapshot -Path $entry.Value -Name $entry.Key -ExpectedAssets $expectedAssets
    }
    $packageFile = Get-Item -LiteralPath $packagePath
    $packageSha1 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA1).Hash
    if (
        $packageFile.Length -ne $fullPackages[0].Size -or
        $packageSha1.ToLowerInvariant() -ne ([string]$fullPackages[0].SHA1).ToLowerInvariant() -or
        $checksums[$packageName] -ne ([string]$fullPackages[0].SHA256).ToLowerInvariant()
    ) {
        throw "Downloaded full update package differs from its feed metadata."
    }
    $setupSignature = $null
    if (-not $IdentityOnly) {
        $setupSignature = Assert-TimestampedAuthenticode -Path $setupPath -Label "Setup"
    }
    Assert-ExecutableReleaseVersion -Path $setupPath -ExpectedVersion $manifest.version -Label "Setup"

    $extractPath = Join-Path $temporaryRoot "portable"
    Expand-ZipArchiveSafely -ArchivePath $portablePath -Destination $extractPath
    $mainExecutables = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "HoverPocket.Shell.exe")
    if ($mainExecutables.Count -ne 1) {
        throw "Portable ZIP does not contain exactly one HoverPocket.Shell.exe."
    }
    $mainSignature = $null
    if (-not $IdentityOnly) {
        $mainSignature = Assert-TimestampedAuthenticode -Path $mainExecutables[0].FullName -Label "HoverPocket.Shell.exe"
    }
    Assert-ExecutableReleaseVersion -Path $mainExecutables[0].FullName -ExpectedVersion $manifest.version -Label "Portable HoverPocket.Shell.exe"

    $packageExtractPath = Join-Path $temporaryRoot "update-package"
    Expand-ZipArchiveSafely -ArchivePath $packagePath -Destination $packageExtractPath
    Assert-NupkgReleaseIdentity `
        -PackageRoot $packageExtractPath `
        -ExpectedPackageId $manifest.packageId `
        -ExpectedVersion $manifest.version `
        -ExpectedChannel $manifest.updateChannel `
        -ExpectedRuntime $manifest.runtime `
        -Label "Full update package"
    $packageExecutables = @(Get-ChildItem -LiteralPath $packageExtractPath -Recurse -File -Filter "HoverPocket.Shell.exe")
    if ($packageExecutables.Count -ne 1) {
        throw "Full update package does not contain exactly one HoverPocket.Shell.exe."
    }
    $packageSignature = $null
    if (-not $IdentityOnly) {
        $packageSignature = Assert-TimestampedAuthenticode -Path $packageExecutables[0].FullName -Label "Full package HoverPocket.Shell.exe"
    }
    Assert-ExecutableReleaseVersion -Path $packageExecutables[0].FullName -ExpectedVersion $manifest.version -Label "Full package HoverPocket.Shell.exe"
    Assert-AssemblyReleaseVersion -PackageRoot $packageExtractPath -ExpectedVersion $manifest.version
    Assert-PortablePayloadMatchesFullPackage -PortableRoot $extractPath -PackageRoot $packageExtractPath

    Assert-SetupEmbedsFullPackage -SetupPath $setupPath -PackagePath $packagePath
    if (-not $IdentityOnly) {
        $signerThumbprints = @(@(
                $setupSignature.SignerCertificate.Thumbprint
                $mainSignature.SignerCertificate.Thumbprint
                $packageSignature.SignerCertificate.Thumbprint
            ) | Select-Object -Unique)
        if ($signerThumbprints.Count -ne 1) {
            throw "Setup, Portable application, and full update package application are signed by different certificates."
        }
    }
    $finalRelease = Resolve-WindowsRelease -RequestedTag $releaseTag
    Assert-ReleaseMatchesSnapshot -Release $finalRelease -ExpectedAssets $expectedAssets

    [ordered]@{
        status = "passed"
        releaseTag = $releaseTag
        verificationMode = if ($IdentityOnly) { "package-identity" } else { "formal-authenticode" }
        setup = if ($IdentityOnly) { "release-version-verified" } else { "signed-timestamped-verified" }
        portableApplication = if ($IdentityOnly) { "release-version-verified" } else { "signed-timestamped-verified" }
        updatePackageApplication = if ($IdentityOnly) { "release-version-verified" } else { "signed-timestamped-verified" }
        packageIdentity = "manifest-version-and-runtime-verified"
        embeddedApplicationVersion = "verified"
        portablePayload = "full-package-application-byte-equivalent"
        setupPayload = "full-package-byte-equivalent"
        signerAgreement = if ($IdentityOnly) { "not-evaluated" } else { "verified" }
        artifactSnapshot = "verified"
    } | ConvertTo-Json -Compress
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}
