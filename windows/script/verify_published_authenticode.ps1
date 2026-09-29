[CmdletBinding()]
param(
    [string]$Repository = "shotaro311/hover-pocket",
    [string]$Tag = "auto",
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSnapshotPath,
    [string]$ExpectedSignerCertificateSha256 = "",
    [switch]$IdentityOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not ("HoverPocket.ReleaseReadback.VelopackBundleReader" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;

namespace HoverPocket.ReleaseReadback
{
    public sealed class VelopackBundleInfo
    {
        public long Offset { get; private set; }
        public long Length { get; private set; }

        public VelopackBundleInfo(long offset, long length)
        {
            Offset = offset;
            Length = length;
        }
    }

    public static class VelopackBundleReader
    {
        private static readonly byte[] Signature = new byte[] {
            0x94, 0xf0, 0xb1, 0x7b, 0x68, 0x93, 0xe0, 0x29,
            0x37, 0xeb, 0x34, 0xef, 0x53, 0xaa, 0xe7, 0xd4,
            0x2b, 0x54, 0xf5, 0x70, 0x7e, 0xf5, 0xd6, 0xf5,
            0x78, 0x54, 0x98, 0x3e, 0x5e, 0x94, 0xed, 0x7d
        };

        public static VelopackBundleInfo Read(string path)
        {
            long signatureOffset = FindUniqueSignature(path);
            if (signatureOffset < 16) {
                throw new InvalidDataException("Velopack bundle header is truncated.");
            }

            using (FileStream stream = File.OpenRead(path))
            using (BinaryReader reader = new BinaryReader(stream)) {
                stream.Position = signatureOffset - 16;
                long bundleOffset = reader.ReadInt64();
                long bundleLength = reader.ReadInt64();
                if (
                    bundleOffset <= 0 ||
                    bundleLength <= 0 ||
                    signatureOffset + Signature.Length > bundleOffset ||
                    bundleOffset > stream.Length ||
                    bundleLength > stream.Length - bundleOffset
                ) {
                    throw new InvalidDataException("Velopack bundle range is invalid.");
                }
                return new VelopackBundleInfo(bundleOffset, bundleLength);
            }
        }

        private static long FindUniqueSignature(string path)
        {
            const int readSize = 1024 * 1024;
            byte[] buffer = new byte[readSize];
            int[] prefix = BuildPrefixTable();
            int matched = 0;
            long position = 0;
            long foundOffset = -1;

            using (FileStream stream = File.OpenRead(path)) {
                while (true) {
                    int read = stream.Read(buffer, 0, buffer.Length);
                    if (read == 0) {
                        break;
                    }
                    for (int index = 0; index < read; index++, position++) {
                        while (matched > 0 && buffer[index] != Signature[matched]) {
                            matched = prefix[matched - 1];
                        }
                        if (buffer[index] == Signature[matched]) {
                            matched++;
                        }
                        if (matched == Signature.Length) {
                            long absoluteOffset = position - Signature.Length + 1;
                            if (foundOffset >= 0) {
                                throw new InvalidDataException("Velopack bundle signature is duplicated.");
                            }
                            foundOffset = absoluteOffset;
                            matched = prefix[matched - 1];
                        }
                    }
                }
            }

            if (foundOffset < 0) {
                throw new InvalidDataException("Velopack bundle signature was not found.");
            }
            return foundOffset;
        }

        private static int[] BuildPrefixTable()
        {
            int[] prefix = new int[Signature.Length];
            int matched = 0;
            for (int index = 1; index < Signature.Length; index++) {
                while (matched > 0 && Signature[index] != Signature[matched]) {
                    matched = prefix[matched - 1];
                }
                if (Signature[index] == Signature[matched]) {
                    matched++;
                }
                prefix[index] = matched;
            }
            return prefix;
        }
    }
}
"@
}

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
        $bundle = [HoverPocket.ReleaseReadback.VelopackBundleReader]::Read($SetupPath)
        if ($bundle.Length -ne $packageStream.Length) {
            throw "Setup embedded package length differs from the published full update package."
        }

        function Get-RangeSha256 {
            param([IO.Stream]$Stream, [long]$Offset, [long]$Length)

            if ($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt $Stream.Length -or $Length -gt $Stream.Length - $Offset) {
                throw "Hash range is outside the source stream."
            }
            if ($Stream.Seek($Offset, [IO.SeekOrigin]::Begin) -ne $Offset) {
                throw "Hash range offset could not be reached."
            }
            $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                $buffer = [byte[]]::new(1048576)
                [long]$remaining = $Length
                while ($remaining -gt 0) {
                    $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
                    $read = $Stream.Read($buffer, 0, $requested)
                    if ($read -le 0) {
                        throw "Hash range ended before the declared length."
                    }
                    $hash.AppendData($buffer, 0, $read)
                    $remaining -= $read
                }
                return [Convert]::ToHexString($hash.GetHashAndReset())
            }
            finally {
                $hash.Dispose()
            }
        }

        $setupPayloadHash = Get-RangeSha256 -Stream $setupStream -Offset $bundle.Offset -Length $bundle.Length
        $packageHash = Get-RangeSha256 -Stream $packageStream -Offset 0 -Length $packageStream.Length
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

function Get-CertificateSha256 {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($hash.ComputeHash($Certificate.RawData))
    }
    finally {
        $hash.Dispose()
    }
}

function Get-RequiredObjectProperty {
    param($Object, [string]$Name, [string]$FailureCode)

    if ($null -eq $Object -or $Object.PSObject.Properties.Name -cnotcontains $Name) {
        throw $FailureCode
    }
    return $Object.$Name
}

function Read-CodexSandboxManifestContract {
    param(
        $Manifest,
        $Release,
        [bool]$IdentityOnlyMode,
        [string]$ExpectedSignerCertificateSha256
    )

    $schemaVersion = [int](Get-RequiredObjectProperty -Object $Manifest -Name "schemaVersion" -FailureCode "HP_RELEASE_MANIFEST_SCHEMA_MISSING")
    $codexMsiAssets = @($Release.assets | Where-Object { ([string]$_.name) -match '^HoverPocket\.CodexSandboxSetup-\d+\.\d+\.\d+-win-x64\.msi$' })
    if ($schemaVersion -eq 1) {
        if (-not $IdentityOnlyMode) {
            throw "HP_CODEX_SANDBOX_FORMAL_MANIFEST_SCHEMA_REQUIRED"
        }
        if ($codexMsiAssets.Count -ne 0) {
            throw "HP_CODEX_SANDBOX_LEGACY_MANIFEST_MSI_REJECTED"
        }
        return $null
    }
    if ($schemaVersion -ne 2) {
        throw "HP_RELEASE_MANIFEST_SCHEMA_UNSUPPORTED"
    }

    $contract = Get-RequiredObjectProperty -Object $Manifest -Name "codexSandboxSetup" -FailureCode "HP_CODEX_SANDBOX_MANIFEST_MISSING"
    foreach ($field in @(
        "trustedProductionSetupBoundary",
        "productionSetupAvailable",
        "productionGenerationAvailable",
        "productionActivationAvailable")) {
        if ((Get-RequiredObjectProperty -Object $contract -Name $field -FailureCode "HP_CODEX_SANDBOX_MANIFEST_FIELD_MISSING") -ne $false) {
            throw "HP_CODEX_SANDBOX_PRODUCTION_FLAG_ENABLED"
        }
    }

    $published = Get-RequiredObjectProperty -Object $contract -Name "published" -FailureCode "HP_CODEX_SANDBOX_PUBLISHED_STATE_MISSING"
    $manifestAuthenticode = [string](Get-RequiredObjectProperty -Object $Manifest -Name "authenticode" -FailureCode "HP_RELEASE_AUTHENTICODE_STATE_MISSING")
    if ($manifestAuthenticode -ceq "unsigned") {
        if (-not $IdentityOnlyMode -or $published -ne $false -or $codexMsiAssets.Count -ne 0) {
            throw "HP_CODEX_SANDBOX_BETA_TRUST_BOUNDARY_PUBLISHED"
        }
        return $null
    }
    if ($manifestAuthenticode -cne "signed-timestamped-verified" -or $published -ne $true) {
        throw "HP_CODEX_SANDBOX_FORMAL_MSI_NOT_PUBLISHED"
    }
    $expectedAssetName = "HoverPocket.CodexSandboxSetup-$($Manifest.version)-win-x64.msi"
    $assetName = [string](Get-RequiredObjectProperty -Object $contract -Name "assetName" -FailureCode "HP_CODEX_SANDBOX_MSI_NAME_MISSING")
    if ($assetName -cne $expectedAssetName -or $codexMsiAssets.Count -ne 1 -or [string]$codexMsiAssets[0].name -cne $expectedAssetName) {
        throw "HP_CODEX_SANDBOX_MSI_NAME_MISMATCH"
    }
    [long]$assetSize = 0
    if (-not [long]::TryParse(([string](Get-RequiredObjectProperty -Object $contract -Name "assetSize" -FailureCode "HP_CODEX_SANDBOX_MSI_SIZE_MISSING")), [ref]$assetSize) -or $assetSize -le 0) {
        throw "HP_CODEX_SANDBOX_MSI_SIZE_INVALID"
    }
    $assetSha256 = ([string](Get-RequiredObjectProperty -Object $contract -Name "assetSha256" -FailureCode "HP_CODEX_SANDBOX_MSI_SHA256_MISSING")).ToLowerInvariant()
    if ($assetSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "HP_CODEX_SANDBOX_MSI_SHA256_INVALID"
    }
    if ((Get-RequiredObjectProperty -Object $contract -Name "msiAuthenticode" -FailureCode "HP_CODEX_SANDBOX_MSI_AUTHENTICODE_MISSING") -cne "signed-timestamped-verified" -or
        (Get-RequiredObjectProperty -Object $contract -Name "msiTimestamp" -FailureCode "HP_CODEX_SANDBOX_MSI_TIMESTAMP_MISSING") -cne "verified") {
        throw "HP_CODEX_SANDBOX_MSI_AUTHENTICODE_STATE_INVALID"
    }
    if ((Get-RequiredObjectProperty -Object $contract -Name "publisherAgreement" -FailureCode "HP_CODEX_SANDBOX_PUBLISHER_AGREEMENT_MISSING") -cne "shell-helper-msi-same-certificate") {
        throw "HP_CODEX_SANDBOX_PUBLISHER_AGREEMENT_INVALID"
    }
    $declaredSigner = ([string](Get-RequiredObjectProperty -Object $contract -Name "signerCertificateSha256" -FailureCode "HP_CODEX_SANDBOX_SIGNER_SHA256_MISSING")).ToUpperInvariant()
    if ($declaredSigner -notmatch '^[0-9A-F]{64}$' -or
        (-not $IdentityOnlyMode -and $declaredSigner -cne $ExpectedSignerCertificateSha256)) {
        throw "HP_CODEX_SANDBOX_SIGNER_SHA256_MISMATCH"
    }

    $embeddedHelper = Get-RequiredObjectProperty -Object $contract -Name "embeddedHelper" -FailureCode "HP_CODEX_SANDBOX_EMBEDDED_HELPER_MISSING"
    if ((Get-RequiredObjectProperty -Object $embeddedHelper -Name "fileName" -FailureCode "HP_CODEX_SANDBOX_HELPER_NAME_MISSING") -cne "HoverPocket.CodexSandboxSetup.exe") {
        throw "HP_CODEX_SANDBOX_HELPER_NAME_MISMATCH"
    }
    [long]$helperSize = 0
    if (-not [long]::TryParse(([string](Get-RequiredObjectProperty -Object $embeddedHelper -Name "size" -FailureCode "HP_CODEX_SANDBOX_HELPER_SIZE_MISSING")), [ref]$helperSize) -or $helperSize -le 0) {
        throw "HP_CODEX_SANDBOX_HELPER_SIZE_INVALID"
    }
    $helperSha256 = ([string](Get-RequiredObjectProperty -Object $embeddedHelper -Name "sha256" -FailureCode "HP_CODEX_SANDBOX_HELPER_SHA256_MISSING")).ToLowerInvariant()
    if ($helperSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "HP_CODEX_SANDBOX_HELPER_SHA256_INVALID"
    }
    if ((Get-RequiredObjectProperty -Object $embeddedHelper -Name "authenticode" -FailureCode "HP_CODEX_SANDBOX_HELPER_AUTHENTICODE_MISSING") -cne "signed-timestamped-verified" -or
        (Get-RequiredObjectProperty -Object $embeddedHelper -Name "timestamp" -FailureCode "HP_CODEX_SANDBOX_HELPER_TIMESTAMP_MISSING") -cne "verified") {
        throw "HP_CODEX_SANDBOX_HELPER_SIGNATURE_STATE_INVALID"
    }

    return [pscustomobject]@{
        AssetName = $assetName
        AssetSize = $assetSize
        AssetSha256 = $assetSha256
        HelperSize = $helperSize
        HelperSha256 = $helperSha256
    }
}

function Expand-CodexSandboxMsiAdministrativeImage {
    param([string]$MsiPath, [string]$Destination)

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $arguments = @(
        "/a",
        "`"$MsiPath`"",
        "/qn",
        "/norestart",
        "TARGETDIR=`"$Destination`""
    )
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "HP_CODEX_SANDBOX_MSI_ADMIN_IMAGE_FAILED"
    }
    $helpers = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter "HoverPocket.CodexSandboxSetup.exe")
    if ($helpers.Count -ne 1) {
        throw "HP_CODEX_SANDBOX_MSI_EMBEDDED_HELPER_NOT_EXACT"
    }
    $helper = Get-Item -LiteralPath $helpers[0].FullName -Force
    if (($helper.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "HP_CODEX_SANDBOX_MSI_EMBEDDED_HELPER_REPARSE_REJECTED"
    }
    return $helper.FullName
}

$canonicalSignerCertificateSha256 = $null
if (-not $IdentityOnly) {
    $canonicalSignerCertificateSha256 = $ExpectedSignerCertificateSha256.Trim().ToUpperInvariant()
    if ($canonicalSignerCertificateSha256 -notmatch '^[0-9A-F]{64}$') {
        throw "Expected Windows signer certificate SHA-256 must be configured as exactly 64 hexadecimal characters."
    }
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
    $codexSandboxContract = Read-CodexSandboxManifestContract `
        -Manifest $manifest `
        -Release $release `
        -IdentityOnlyMode $IdentityOnly.IsPresent `
        -ExpectedSignerCertificateSha256 $canonicalSignerCertificateSha256
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
    $codexSandboxMsiPath = $null
    if ($null -ne $codexSandboxContract) {
        $codexSandboxMsiPath = Join-Path $temporaryRoot $codexSandboxContract.AssetName
        Get-ReleaseAsset -Release $release -Name $codexSandboxContract.AssetName -Destination $codexSandboxMsiPath
    }

    $checksums = Read-Checksums -Path $checksumPath
    Assert-DownloadedChecksum -Path $manifestPath -Name "release-manifest.win.json" -Checksums $checksums
    Assert-DownloadedChecksum -Path $feedPath -Name "releases.win.json" -Checksums $checksums
    Assert-DownloadedChecksum -Path $releasesPath -Name "RELEASES" -Checksums $checksums
    Assert-DownloadedChecksum -Path $assetsPath -Name "assets.win.json" -Checksums $checksums
    Assert-DownloadedChecksum -Path $setupPath -Name $setupAsset[0].name -Checksums $checksums
    Assert-DownloadedChecksum -Path $portablePath -Name $portableAsset[0].name -Checksums $checksums
    Assert-DownloadedChecksum -Path $packagePath -Name $packageName -Checksums $checksums
    if ($null -ne $codexSandboxContract) {
        Assert-DownloadedChecksum -Path $codexSandboxMsiPath -Name $codexSandboxContract.AssetName -Checksums $checksums
        $msiFile = Get-Item -LiteralPath $codexSandboxMsiPath
        $msiSha256 = (Get-FileHash -LiteralPath $codexSandboxMsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($msiFile.Length -ne $codexSandboxContract.AssetSize -or $msiSha256 -cne $codexSandboxContract.AssetSha256) {
            throw "HP_CODEX_SANDBOX_MSI_MANIFEST_READBACK_MISMATCH"
        }
    }
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
    if ($null -ne $codexSandboxContract) {
        $downloadedPaths[$codexSandboxContract.AssetName] = $codexSandboxMsiPath
    }
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

    $codexSandboxMsiSignature = $null
    $codexSandboxHelperSignature = $null
    if ($null -ne $codexSandboxContract -and -not $IdentityOnly) {
        $codexSandboxMsiSignature = Assert-TimestampedAuthenticode -Path $codexSandboxMsiPath -Label "Codex sandbox MSI"
        $codexSandboxMsiSignerCertificateSha256 = (Get-CertificateSha256 -Certificate $codexSandboxMsiSignature.SignerCertificate).ToUpperInvariant()
        if ($codexSandboxMsiSignerCertificateSha256 -cne $canonicalSignerCertificateSha256) {
            throw "Published Codex sandbox MSI is not signed by the configured HoverPocket publisher certificate."
        }
        $installerVerifierPath = Join-Path $PSScriptRoot "verify_codex_sandbox_installer.ps1"
        & $installerVerifierPath `
            -MsiPath $codexSandboxMsiPath `
            -ExpectedProductVersion $manifest.version `
            -ExpectedUpgradeCode "{9E28ABD6-A496-472E-98AB-AE8D70C27B48}" | Out-Null
        $codexSandboxAdminRoot = Join-Path $temporaryRoot "codex-sandbox-msi-admin-image"
        $embeddedHelperPath = Expand-CodexSandboxMsiAdministrativeImage -MsiPath $codexSandboxMsiPath -Destination $codexSandboxAdminRoot
        $embeddedHelperFile = Get-Item -LiteralPath $embeddedHelperPath
        $embeddedHelperSha256 = (Get-FileHash -LiteralPath $embeddedHelperPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($embeddedHelperFile.Length -ne $codexSandboxContract.HelperSize -or $embeddedHelperSha256 -cne $codexSandboxContract.HelperSha256) {
            throw "HP_CODEX_SANDBOX_EMBEDDED_HELPER_MANIFEST_READBACK_MISMATCH"
        }
        $codexSandboxHelperSignature = Assert-TimestampedAuthenticode -Path $embeddedHelperPath -Label "Embedded Codex sandbox helper"
    }

    Assert-SetupEmbedsFullPackage -SetupPath $setupPath -PackagePath $packagePath
    if (-not $IdentityOnly) {
        $signerCertificateSha256s = @(@(
                Get-CertificateSha256 -Certificate $setupSignature.SignerCertificate
                Get-CertificateSha256 -Certificate $mainSignature.SignerCertificate
                Get-CertificateSha256 -Certificate $packageSignature.SignerCertificate
                Get-CertificateSha256 -Certificate $codexSandboxMsiSignature.SignerCertificate
                Get-CertificateSha256 -Certificate $codexSandboxHelperSignature.SignerCertificate
            ) | Select-Object -Unique)
        if ($signerCertificateSha256s.Count -ne 1) {
            throw "Shell/Velopack artifacts, Codex sandbox MSI, and embedded helper are signed by different certificates."
        }
        if (([string]$signerCertificateSha256s[0]).ToUpperInvariant() -cne $canonicalSignerCertificateSha256) {
            throw "Published artifacts are not signed by the configured HoverPocket publisher certificate."
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
        codexSandboxMsi = if ($null -eq $codexSandboxContract) { "not-published" } elseif ($IdentityOnly) { "package-identity-verified" } else { "signed-timestamped-verified" }
        codexSandboxEmbeddedHelper = if ($null -eq $codexSandboxContract) { "not-published" } elseif ($IdentityOnly) { "manifest-bound-not-extracted" } else { "signed-timestamped-verified" }
        packageIdentity = "manifest-version-and-runtime-verified"
        embeddedApplicationVersion = "verified"
        portablePayload = "full-package-application-byte-equivalent"
        setupPayload = "full-package-byte-equivalent"
        signerAgreement = if ($IdentityOnly) { "not-evaluated" } else { "verified" }
        publisherIdentity = if ($IdentityOnly) { "not-evaluated" } else { "verified" }
        codexSandboxPublisherAgreement = if ($IdentityOnly) { "not-evaluated" } else { "shell-helper-msi-same-certificate-verified" }
        productionSetupBoundary = "disabled"
        artifactSnapshot = "verified"
    } | ConvertTo-Json -Compress
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}
