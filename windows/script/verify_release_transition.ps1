[CmdletBinding()]
param(
    [string]$Repository = "shotaro311/hover-pocket",
    [Parameter(Mandatory = $true)][string]$PreviousTag,
    [Parameter(Mandatory = $true)][string]$CurrentTag,
    [switch]$AllowUnsignedBeta,
    [string]$ExpectedSignerCertificateSha256 = "",
    [switch]$CodexSandboxInstallerTransition,
    [switch]$CodexSandboxInstallerContractTest,
    [switch]$SnapshotContractTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-GitHubHeaders {
    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "HoverPocket-release-transition/1"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($token) { $headers.Authorization = "Bearer $token" }
    return $headers
}

function Get-Release {
    param([string]$Tag)

    if ($Tag -notmatch '^win-v\d+\.\d+\.\d+$') {
        throw "Release tag must match win-vMAJOR.MINOR.PATCH."
    }
    $encoded = [Uri]::EscapeDataString($Tag)
    $release = Invoke-RestMethod -Headers (Get-GitHubHeaders) -Uri "https://api.github.com/repos/$Repository/releases/tags/$encoded"
    if ($release.draft -or $release.prerelease -or $release.tag_name -ne $Tag) {
        throw "Release $Tag is not a matching published release."
    }
    return $release
}

function Get-ReleaseAssetSnapshot {
    param($Release)

    $assets = [System.Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($asset in @($Release.assets)) {
        $name = [string]$asset.name
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Release contains an unsafe asset name."
        }
        if ($assets.ContainsKey($name)) {
            throw "Release asset $name is duplicated."
        }
        $size = [long]$asset.size
        if ($size -lt 0) {
            throw "Release asset $name has an invalid size."
        }
        $digest = [string]$asset.digest
        if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw "Release asset $name has an invalid digest."
        }
        $url = [string]$asset.browser_download_url
        $expectedUrl = "https://github.com/$Repository/releases/download/$($Release.tag_name)/$name"
        if ($url -cne $expectedUrl) {
            throw "Release asset $name has an unexpected download URL."
        }
        $assets.Add($name, [pscustomobject]@{
            Size = $size
            Digest = $digest
            Url = $url
        })
    }
    return [pscustomobject]@{
        Tag = [string]$Release.tag_name
        Assets = $assets
    }
}

function Assert-ReleaseMatchesSnapshot {
    param($Release, $Expected)

    $actual = Get-ReleaseAssetSnapshot -Release $Release
    if ($actual.Tag -cne $Expected.Tag -or $actual.Assets.Count -ne $Expected.Assets.Count) {
        throw "Release snapshot identity or asset count changed during transition verification."
    }
    foreach ($entry in $Expected.Assets.GetEnumerator()) {
        if (-not $actual.Assets.ContainsKey($entry.Key)) {
            throw "Release asset $($entry.Key) disappeared during transition verification."
        }
        $actualAsset = $actual.Assets[$entry.Key]
        if (
            $actualAsset.Size -ne $entry.Value.Size -or
            $actualAsset.Digest -cne $entry.Value.Digest -or
            $actualAsset.Url -cne $entry.Value.Url
        ) {
            throw "Release asset $($entry.Key) changed during transition verification."
        }
    }
}

function Get-ReleaseAssetRecord {
    param($Release, [string]$Name)

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
    return $matches[0]
}

function Save-ReleaseAsset {
    param($Release, [string]$Name, [string]$Directory)

    $record = Get-ReleaseAssetRecord -Release $Release -Name $Name
    $path = Join-Path $Directory $Name
    Invoke-WebRequest -Headers @{ "User-Agent" = "HoverPocket-release-transition/1" } -Uri $record.browser_download_url -OutFile $path
    if ((Get-Item -LiteralPath $path).Length -ne [long]$record.size) {
        throw "Downloaded size differs for $Name."
    }
    $actualDigest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$record.digest -cne ("sha256:" + $actualDigest)) {
        throw "GitHub digest differs for $Name."
    }
    return $path
}

function Read-Checksums {
    param([string]$Path)

    $result = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::ASCII)) {
        if (-not $line) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$') {
            throw "Checksum file contains a malformed line."
        }
        if ($result.ContainsKey($Matches[2])) {
            throw "Checksum file contains a duplicate asset."
        }
        $result[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }
    return $result
}

function Assert-Checksum {
    param([string]$Path, [string]$Name, [hashtable]$Checksums)

    if (-not $Checksums.ContainsKey($Name)) {
        throw "Checksum file does not cover $Name."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Checksums[$Name]) {
        throw "Downloaded checksum differs for $Name."
    }
}

function Assert-ApplicationTransitionManifestContract {
    param($Manifest, $Release)

    $schemaVersion = [int](Get-RequiredProperty -Object $Manifest -Name "schemaVersion" -FailureCode "HP_RELEASE_TRANSITION_SCHEMA_MISSING")
    if ($schemaVersion -notin @(1, 2) -or
        $Manifest.product -cne "HoverPocket" -or
        $Manifest.packageId -cne "HoverPocketWin") {
        throw "Release manifest identity is invalid."
    }

    $codexMsiAssets = @($Release.assets | Where-Object { ([string]$_.name) -match '^HoverPocket\.CodexSandboxSetup-\d+\.\d+\.\d+-win-x64\.msi$' })
    if ($schemaVersion -eq 1) {
        if ($codexMsiAssets.Count -ne 0) {
            throw "HP_CODEX_SANDBOX_TRANSITION_LEGACY_MANIFEST_MSI_REJECTED"
        }
        return
    }

    $contract = Get-RequiredProperty -Object $Manifest -Name "codexSandboxSetup" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_CONTRACT_MISSING"
    foreach ($field in @(
        "trustedProductionSetupBoundary",
        "productionSetupAvailable",
        "productionGenerationAvailable",
        "productionActivationAvailable")) {
        if ((Get-RequiredProperty -Object $contract -Name $field -FailureCode "HP_CODEX_SANDBOX_TRANSITION_FLAG_MISSING") -ne $false) {
            throw "HP_CODEX_SANDBOX_TRANSITION_PRODUCTION_FLAG_ENABLED"
        }
    }

    $published = Get-RequiredProperty -Object $contract -Name "published" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_PUBLISHED_MISSING"
    if ($Manifest.authenticode -ceq "unsigned") {
        if ($published -ne $false -or $codexMsiAssets.Count -ne 0) {
            throw "HP_CODEX_SANDBOX_TRANSITION_BETA_TRUST_BOUNDARY_PUBLISHED"
        }
        return
    }
    if ($Manifest.authenticode -ceq "signed-timestamped-verified" -and
        ($published -ne $true -or $codexMsiAssets.Count -ne 1)) {
        throw "HP_CODEX_SANDBOX_TRANSITION_FORMAL_MSI_NOT_PUBLISHED"
    }
}

function Get-ReleasePackage {
    param($Release, $Snapshot, [string]$Directory)

    $manifestPath = Save-ReleaseAsset -Release $Release -Name "release-manifest.win.json" -Directory $Directory
    $checksumPath = Save-ReleaseAsset -Release $Release -Name "SHA256SUMS-win.txt" -Directory $Directory
    $feedPath = Save-ReleaseAsset -Release $Release -Name "releases.win.json" -Directory $Directory
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $feed = Get-Content -LiteralPath $feedPath -Raw | ConvertFrom-Json
    Assert-ApplicationTransitionManifestContract -Manifest $manifest -Release $Release
    if ($Release.tag_name -ne "win-v$($manifest.version)") {
        throw "Release tag and manifest version differ."
    }
    $isUnsignedBeta = $manifest.authenticode -eq "unsigned"
    if ($isUnsignedBeta) {
        if (-not $AllowUnsignedBeta) { throw "Unsigned release execution requires AllowUnsignedBeta." }
    }
    elseif ($manifest.authenticode -eq "signed-timestamped-verified") {
        throw "Formal signed transition is blocked until the package and embedded application signatures are bound to an independently verified release snapshot."
    }
    else {
        throw "Release manifest contains an unknown Authenticode state."
    }

    $setupName = "HoverPocketWin-win-Setup.exe"
    $fullPackages = @($feed.Assets | Where-Object { $_.Type -eq "Full" })
    if ($fullPackages.Count -ne 1 -or $fullPackages[0].Version -ne $manifest.version) {
        throw "Windows feed must contain exactly one matching full package."
    }
    $packageName = [string]$fullPackages[0].FileName
    $expectedPackageName = "HoverPocketWin-$($manifest.version)-full.nupkg"
    if ($packageName -cne $expectedPackageName) {
        throw "Windows feed full package name is not canonical."
    }
    $setupRecords = @($Release.assets | Where-Object { $_.name -ceq $setupName })
    $packageRecords = @($Release.assets | Where-Object { $_.name -ceq $packageName })
    if ($setupRecords.Count -ne 1 -or $packageRecords.Count -ne 1) {
        throw "Release must contain exactly one Setup and one full package."
    }
    $setupPath = Save-ReleaseAsset -Release $Release -Name $setupName -Directory $Directory
    $packagePath = Save-ReleaseAsset -Release $Release -Name $packageName -Directory $Directory
    $checksums = Read-Checksums -Path $checksumPath
    Assert-Checksum -Path $manifestPath -Name "release-manifest.win.json" -Checksums $checksums
    Assert-Checksum -Path $feedPath -Name "releases.win.json" -Checksums $checksums
    Assert-Checksum -Path $setupPath -Name $setupName -Checksums $checksums
    Assert-Checksum -Path $packagePath -Name $packageName -Checksums $checksums
    $packageFile = Get-Item -LiteralPath $packagePath
    $packageSha1 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA1).Hash
    if (
        $packageFile.Length -ne [long]$fullPackages[0].Size -or
        $packageSha1 -cne ([string]$fullPackages[0].SHA1).ToUpperInvariant() -or
        $checksums[$packageName] -cne ([string]$fullPackages[0].SHA256).ToLowerInvariant()
    ) {
        throw "Downloaded full package differs from its feed metadata."
    }

    return [pscustomobject]@{
        Version = [string]$manifest.version
        SetupPath = $setupPath
        PackagePath = $packagePath
        Authenticode = [string]$manifest.authenticode
        SigningMode = "explicit-beta"
        Snapshot = $Snapshot
    }
}

function Get-CertificateSha256 {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    if ($null -eq $Certificate) {
        throw "HP_CODEX_SANDBOX_TRANSITION_SIGNER_MISSING"
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($hash.ComputeHash($Certificate.RawData))
    }
    finally {
        $hash.Dispose()
    }
}

function Assert-TimestampedAuthenticode {
    param([string]$Path, [string]$ExpectedCertificateSha256, [string]$Label)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $null -eq $signature.TimeStamperCertificate) {
        throw "HP_CODEX_SANDBOX_TRANSITION_SIGNATURE_INVALID"
    }
    if ((Get-CertificateSha256 -Certificate $signature.SignerCertificate) -cne $ExpectedCertificateSha256) {
        throw "HP_CODEX_SANDBOX_TRANSITION_PUBLISHER_MISMATCH"
    }
}

function Get-RequiredProperty {
    param($Object, [string]$Name, [string]$FailureCode)

    if ($null -eq $Object -or $Object.PSObject.Properties.Name -cnotcontains $Name) {
        throw $FailureCode
    }
    return $Object.$Name
}

function Read-CodexSandboxTransitionManifest {
    param($Manifest, $Release, [string]$ExpectedCertificateSha256)

    if ([int](Get-RequiredProperty -Object $Manifest -Name "schemaVersion" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_SCHEMA_MISSING") -ne 2 -or
        $Manifest.authenticode -cne "signed-timestamped-verified") {
        throw "HP_CODEX_SANDBOX_TRANSITION_FORMAL_MANIFEST_REQUIRED"
    }
    $contract = Get-RequiredProperty -Object $Manifest -Name "codexSandboxSetup" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_CONTRACT_MISSING"
    foreach ($field in @(
        "trustedProductionSetupBoundary",
        "productionSetupAvailable",
        "productionGenerationAvailable",
        "productionActivationAvailable")) {
        if ((Get-RequiredProperty -Object $contract -Name $field -FailureCode "HP_CODEX_SANDBOX_TRANSITION_FLAG_MISSING") -ne $false) {
            throw "HP_CODEX_SANDBOX_TRANSITION_PRODUCTION_FLAG_ENABLED"
        }
    }
    if ((Get-RequiredProperty -Object $contract -Name "published" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_PUBLISHED_MISSING") -ne $true -or
        (Get-RequiredProperty -Object $contract -Name "msiAuthenticode" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_MSI_SIGNATURE_STATE_MISSING") -cne "signed-timestamped-verified" -or
        (Get-RequiredProperty -Object $contract -Name "msiTimestamp" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_MSI_TIMESTAMP_MISSING") -cne "verified" -or
        (Get-RequiredProperty -Object $contract -Name "publisherAgreement" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_PUBLISHER_AGREEMENT_MISSING") -cne "shell-helper-msi-same-certificate") {
        throw "HP_CODEX_SANDBOX_TRANSITION_FORMAL_CONTRACT_INVALID"
    }
    $declaredSigner = ([string](Get-RequiredProperty -Object $contract -Name "signerCertificateSha256" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_SIGNER_MISSING")).ToUpperInvariant()
    if ($declaredSigner -cne $ExpectedCertificateSha256) {
        throw "HP_CODEX_SANDBOX_TRANSITION_DECLARED_SIGNER_MISMATCH"
    }
    $assetName = [string](Get-RequiredProperty -Object $contract -Name "assetName" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_MSI_NAME_MISSING")
    $expectedAssetName = "HoverPocket.CodexSandboxSetup-$($Manifest.version)-win-x64.msi"
    $assetMatches = @($Release.assets | Where-Object { [string]$_.name -ceq $assetName })
    if ($assetName -cne $expectedAssetName -or $assetMatches.Count -ne 1) {
        throw "HP_CODEX_SANDBOX_TRANSITION_MSI_NAME_MISMATCH"
    }
    [long]$assetSize = [long](Get-RequiredProperty -Object $contract -Name "assetSize" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_MSI_SIZE_MISSING")
    $assetSha256 = ([string](Get-RequiredProperty -Object $contract -Name "assetSha256" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_MSI_SHA256_MISSING")).ToLowerInvariant()
    if ($assetSize -le 0 -or $assetSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "HP_CODEX_SANDBOX_TRANSITION_MSI_METADATA_INVALID"
    }
    $helper = Get-RequiredProperty -Object $contract -Name "embeddedHelper" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_HELPER_MISSING"
    if ((Get-RequiredProperty -Object $helper -Name "fileName" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_HELPER_NAME_MISSING") -cne "HoverPocket.CodexSandboxSetup.exe" -or
        (Get-RequiredProperty -Object $helper -Name "authenticode" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_HELPER_SIGNATURE_STATE_MISSING") -cne "signed-timestamped-verified" -or
        (Get-RequiredProperty -Object $helper -Name "timestamp" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_HELPER_TIMESTAMP_MISSING") -cne "verified") {
        throw "HP_CODEX_SANDBOX_TRANSITION_HELPER_CONTRACT_INVALID"
    }
    [long]$helperSize = [long](Get-RequiredProperty -Object $helper -Name "size" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_HELPER_SIZE_MISSING")
    $helperSha256 = ([string](Get-RequiredProperty -Object $helper -Name "sha256" -FailureCode "HP_CODEX_SANDBOX_TRANSITION_HELPER_SHA256_MISSING")).ToLowerInvariant()
    if ($helperSize -le 0 -or $helperSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "HP_CODEX_SANDBOX_TRANSITION_HELPER_METADATA_INVALID"
    }
    return [pscustomobject]@{
        Version = [string]$Manifest.version
        AssetName = $assetName
        AssetSize = $assetSize
        AssetSha256 = $assetSha256
        HelperSize = $helperSize
        HelperSha256 = $helperSha256
    }
}

function Expand-CodexSandboxInstallerPayload {
    param([string]$MsiPath, [string]$Destination)

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
        "/a",
        "`"$MsiPath`"",
        "/qn",
        "/norestart",
        "TARGETDIR=`"$Destination`""
    ) -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "HP_CODEX_SANDBOX_TRANSITION_ADMIN_IMAGE_FAILED"
    }
    $helpers = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter "HoverPocket.CodexSandboxSetup.exe")
    if ($helpers.Count -ne 1) {
        throw "HP_CODEX_SANDBOX_TRANSITION_EMBEDDED_HELPER_NOT_EXACT"
    }
    $helper = Get-Item -LiteralPath $helpers[0].FullName -Force
    if (($helper.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "HP_CODEX_SANDBOX_TRANSITION_EMBEDDED_HELPER_REPARSE_REJECTED"
    }
    return $helper.FullName
}

function Get-CodexSandboxReleaseInstaller {
    param($Release, $Snapshot, [string]$Directory, [string]$ExpectedCertificateSha256)

    $manifestPath = Save-ReleaseAsset -Release $Release -Name "release-manifest.win.json" -Directory $Directory
    $checksumPath = Save-ReleaseAsset -Release $Release -Name "SHA256SUMS-win.txt" -Directory $Directory
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$Release.tag_name -cne "win-v$($manifest.version)") {
        throw "HP_CODEX_SANDBOX_TRANSITION_RELEASE_VERSION_MISMATCH"
    }
    $contract = Read-CodexSandboxTransitionManifest -Manifest $manifest -Release $Release -ExpectedCertificateSha256 $ExpectedCertificateSha256
    $msiPath = Save-ReleaseAsset -Release $Release -Name $contract.AssetName -Directory $Directory
    $checksums = Read-Checksums -Path $checksumPath
    Assert-Checksum -Path $manifestPath -Name "release-manifest.win.json" -Checksums $checksums
    Assert-Checksum -Path $msiPath -Name $contract.AssetName -Checksums $checksums
    $msiFile = Get-Item -LiteralPath $msiPath
    $msiSha256 = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($msiFile.Length -ne $contract.AssetSize -or $msiSha256 -cne $contract.AssetSha256) {
        throw "HP_CODEX_SANDBOX_TRANSITION_MSI_READBACK_MISMATCH"
    }
    Assert-TimestampedAuthenticode -Path $msiPath -ExpectedCertificateSha256 $ExpectedCertificateSha256 -Label "Codex sandbox MSI"
    $installerVerifierPath = Join-Path $PSScriptRoot "verify_codex_sandbox_installer.ps1"
    & $installerVerifierPath `
        -MsiPath $msiPath `
        -ExpectedProductVersion $contract.Version `
        -ExpectedUpgradeCode "{9E28ABD6-A496-472E-98AB-AE8D70C27B48}" | Out-Null
    $adminImageRoot = Join-Path $Directory "verified-admin-image"
    $embeddedHelperPath = Expand-CodexSandboxInstallerPayload -MsiPath $msiPath -Destination $adminImageRoot
    $embeddedHelper = Get-Item -LiteralPath $embeddedHelperPath -Force
    $embeddedHelperSha256 = (Get-FileHash -LiteralPath $embeddedHelperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($embeddedHelper.Length -ne $contract.HelperSize -or $embeddedHelperSha256 -cne $contract.HelperSha256) {
        throw "HP_CODEX_SANDBOX_TRANSITION_EMBEDDED_HELPER_READBACK_MISMATCH"
    }
    Assert-TimestampedAuthenticode -Path $embeddedHelperPath -ExpectedCertificateSha256 $ExpectedCertificateSha256 -Label "Embedded Codex sandbox helper"
    return [pscustomobject]@{
        Version = $contract.Version
        MsiPath = $msiPath
        HelperSize = $contract.HelperSize
        HelperSha256 = $contract.HelperSha256
        Snapshot = $Snapshot
    }
}

function Invoke-MsiExec {
    param([string[]]$Arguments, [string]$FailureCode)

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw $FailureCode
    }
}

function Get-CodexSandboxInstalledHelperPath {
    $programFiles64 = if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) { $env:ProgramW6432 } else { $env:ProgramFiles }
    if ([string]::IsNullOrWhiteSpace($programFiles64)) {
        throw "HP_CODEX_SANDBOX_TRANSITION_PROGRAM_FILES_UNAVAILABLE"
    }
    return Join-Path $programFiles64 "HoverPocket\CodexSandboxSetup\HoverPocket.CodexSandboxSetup.exe"
}

function Assert-InstalledCodexSandboxHelper {
    param($ReleaseInstaller, [string]$ExpectedCertificateSha256)

    $helperPath = Get-CodexSandboxInstalledHelperPath
    if (-not [IO.File]::Exists($helperPath)) {
        throw "HP_CODEX_SANDBOX_TRANSITION_INSTALLED_HELPER_MISSING"
    }
    $helperFile = Get-Item -LiteralPath $helperPath -Force
    if (($helperFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "HP_CODEX_SANDBOX_TRANSITION_INSTALLED_HELPER_REPARSE_REJECTED"
    }
    $helperSha256 = (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($helperFile.Length -ne $ReleaseInstaller.HelperSize -or $helperSha256 -cne $ReleaseInstaller.HelperSha256) {
        throw "HP_CODEX_SANDBOX_TRANSITION_INSTALLED_HELPER_READBACK_MISMATCH"
    }
    Assert-TimestampedAuthenticode -Path $helperPath -ExpectedCertificateSha256 $ExpectedCertificateSha256 -Label "Installed Codex sandbox helper"
}

function Invoke-NativeProcess {
    param([string]$Path, [string[]]$Arguments, [string]$Label)

    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "$Label failed with exit code $($process.ExitCode)."
    }
}

function Invoke-NativeProcessWithOutput {
    param([string]$Path, [string[]]$Arguments, [string]$Label)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "$Label failed to start."
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $standardOutput.GetAwaiter().GetResult()
        [void]$standardError.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "$Label failed with exit code $($process.ExitCode)."
        }
        if (-not [string]::IsNullOrEmpty($output)) {
            return @($output -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        }
        return @()
    }
    finally {
        $process.Dispose()
    }
}

function Assert-InstalledVersion {
    param([string]$InstallRoot, [string]$ExpectedVersion)

    $applicationPath = Join-Path $InstallRoot "current\HoverPocket.Shell.exe"
    $updaterPath = Join-Path $InstallRoot "Update.exe"
    if (-not [IO.File]::Exists($applicationPath) -or -not [IO.File]::Exists($updaterPath)) {
        throw "Installed application layout is incomplete."
    }
    $productVersion = (Get-Item -LiteralPath $applicationPath).VersionInfo.ProductVersion
    if (-not $productVersion.StartsWith("$ExpectedVersion+", [StringComparison]::Ordinal)) {
        throw "Installed ProductVersion $productVersion does not match $ExpectedVersion."
    }
    $previousExpected = $env:HOVERPOCKET_RELEASE_EXPECTED_VERSION
    $env:HOVERPOCKET_RELEASE_EXPECTED_VERSION = $ExpectedVersion
    try {
        $verificationOutput = @(Invoke-NativeProcessWithOutput `
            -Path $applicationPath `
            -Arguments @("--verify", "release-config") `
            -Label "Installed release-config verifier")
        $verificationOutput | ForEach-Object { Write-Host $_ }
    }
    finally {
        $env:HOVERPOCKET_RELEASE_EXPECTED_VERSION = $previousExpected
    }
    return [string]$updaterPath
}

function Install-Release {
    param([string]$SetupPath, [string]$InstallRoot, [string]$Label)

    Invoke-NativeProcess -Path $SetupPath -Arguments @("--silent", "--installto", "`"$InstallRoot`"") -Label $Label
}

function Apply-Package {
    param([string]$UpdaterPath, [string]$InstallRoot, [string]$PackagePath, [string]$Label)

    $packageDirectory = Join-Path $InstallRoot "packages"
    [IO.Directory]::CreateDirectory($packageDirectory) | Out-Null
    Invoke-NativeProcess -Path $UpdaterPath -Arguments @(
        "--silent",
        "--rootDir", "`"$InstallRoot`"",
        "--packageDir", "`"$packageDirectory`"",
        "apply",
        "--norestart",
        "--package", "`"$PackagePath`""
    ) -Label $Label
}

if ($CodexSandboxInstallerContractTest) {
    $expectedSigner = "A" * 64
    $assetName = "HoverPocket.CodexSandboxSetup-0.2.7-win-x64.msi"
    $release = [pscustomobject]@{
        tag_name = "win-v0.2.7"
        assets = @([pscustomobject]@{ name = $assetName })
    }
    $manifest = [pscustomobject]@{
        schemaVersion = 2
        version = "0.2.7"
        authenticode = "signed-timestamped-verified"
        codexSandboxSetup = [pscustomobject]@{
            published = $true
            trustedProductionSetupBoundary = $false
            productionSetupAvailable = $false
            productionGenerationAvailable = $false
            productionActivationAvailable = $false
            assetName = $assetName
            assetSize = 123
            assetSha256 = "b" * 64
            msiAuthenticode = "signed-timestamped-verified"
            msiTimestamp = "verified"
            publisherAgreement = "shell-helper-msi-same-certificate"
            signerCertificateSha256 = $expectedSigner
            embeddedHelper = [pscustomobject]@{
                fileName = "HoverPocket.CodexSandboxSetup.exe"
                size = 45
                sha256 = "c" * 64
                authenticode = "signed-timestamped-verified"
                timestamp = "verified"
            }
        }
    }
    [void](Read-CodexSandboxTransitionManifest -Manifest $manifest -Release $release -ExpectedCertificateSha256 $expectedSigner)
    $manifest.codexSandboxSetup.productionSetupAvailable = $true
    $rejected = $false
    try {
        [void](Read-CodexSandboxTransitionManifest -Manifest $manifest -Release $release -ExpectedCertificateSha256 $expectedSigner)
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Codex sandbox production enablement contract was not rejected."
    }
    $manifest.codexSandboxSetup.productionSetupAvailable = $false
    $manifest.codexSandboxSetup.assetName = "HoverPocket.CodexSandboxSetup-0.2.8-win-x64.msi"
    $assetMismatchRejected = $false
    try {
        [void](Read-CodexSandboxTransitionManifest -Manifest $manifest -Release $release -ExpectedCertificateSha256 $expectedSigner)
    }
    catch {
        $assetMismatchRejected = $true
    }
    if (-not $assetMismatchRejected) {
        throw "Codex sandbox MSI asset identity contract was not rejected."
    }
    $manifest.codexSandboxSetup.assetName = $assetName
    $signerMismatchRejected = $false
    try {
        [void](Read-CodexSandboxTransitionManifest -Manifest $manifest -Release $release -ExpectedCertificateSha256 ("D" * 64))
    }
    catch {
        $signerMismatchRejected = $true
    }
    if (-not $signerMismatchRejected) {
        throw "Codex sandbox publisher mismatch contract was not rejected."
    }

    $betaRelease = [pscustomobject]@{
        tag_name = "win-v0.2.7"
        assets = @()
    }
    $betaManifest = [pscustomobject]@{
        schemaVersion = 2
        product = "HoverPocket"
        packageId = "HoverPocketWin"
        version = "0.2.7"
        authenticode = "unsigned"
        codexSandboxSetup = [pscustomobject]@{
            published = $false
            trustedProductionSetupBoundary = $false
            productionSetupAvailable = $false
            productionGenerationAvailable = $false
            productionActivationAvailable = $false
        }
    }
    Assert-ApplicationTransitionManifestContract -Manifest $betaManifest -Release $betaRelease
    $betaManifest.codexSandboxSetup.published = $true
    $betaBoundaryRejected = $false
    try {
        Assert-ApplicationTransitionManifestContract -Manifest $betaManifest -Release $betaRelease
    }
    catch {
        $betaBoundaryRejected = $true
    }
    if (-not $betaBoundaryRejected) {
        throw "Codex sandbox beta publication boundary was not rejected."
    }
    '{"status":"passed","codexSandboxProductionFlagsRejected":true,"assetMismatchRejected":true,"publisherMismatchRejected":true,"schema2BetaApplicationTransitionAccepted":true,"betaBoundaryRejected":true}'
    return
}

if ($SnapshotContractTest) {
    $assetName = "HoverPocketWin-0.2.7-full.nupkg"
    $assetUrl = "https://github.com/$Repository/releases/download/$CurrentTag/$assetName"
    $release = [pscustomobject]@{
        tag_name = $CurrentTag
        assets = @([pscustomobject]@{
            name = $assetName
            size = 123
            digest = "sha256:" + ("a" * 64)
            browser_download_url = $assetUrl
        })
    }
    $snapshot = Get-ReleaseAssetSnapshot -Release $release
    Assert-ReleaseMatchesSnapshot -Release $release -Expected $snapshot

    $changedRelease = [pscustomobject]@{
        tag_name = $CurrentTag
        assets = @([pscustomobject]@{
            name = $assetName
            size = 123
            digest = "sha256:" + ("b" * 64)
            browser_download_url = $assetUrl
        })
    }
    $mutationRejected = $false
    try {
        Assert-ReleaseMatchesSnapshot -Release $changedRelease -Expected $snapshot
    }
    catch {
        $mutationRejected = $true
    }
    if (-not $mutationRejected) {
        throw "Release snapshot mutation contract was not rejected."
    }

    $nativeOutput = @(Invoke-NativeProcessWithOutput `
        -Path $env:ComSpec `
        -Arguments @("/d", "/c", "echo HP_NATIVE_PROCESS_CAPTURE_OK") `
        -Label "Native process capture contract")
    if ($nativeOutput -cnotcontains "HP_NATIVE_PROCESS_CAPTURE_OK") {
        throw "Native process output was not captured."
    }
    $nativeFailureRejected = $false
    try {
        Invoke-NativeProcessWithOutput `
            -Path $env:ComSpec `
            -Arguments @("/d", "/c", "exit /b 7") `
            -Label "Native process failure contract" | Out-Null
    }
    catch {
        $nativeFailureRejected = $_.Exception.Message -ceq "Native process failure contract failed with exit code 7."
    }
    if (-not $nativeFailureRejected) {
        throw "Native process failure exit code was not rejected."
    }
    '{"status":"passed","snapshotMutationRejected":true,"nativeProcessOutputCaptured":true,"nativeProcessFailureRejected":true}'
    return
}

if ($PreviousTag -eq $CurrentTag) {
    throw "PreviousTag and CurrentTag must differ."
}
$previousVersion = [version]$PreviousTag.Substring(5)
$currentVersion = [version]$CurrentTag.Substring(5)
if ($previousVersion -ge $currentVersion) {
    throw "PreviousTag must be older than CurrentTag."
}

if ($CodexSandboxInstallerTransition) {
    $canonicalSigner = $ExpectedSignerCertificateSha256.Trim().ToUpperInvariant()
    if ($canonicalSigner -notmatch '^[0-9A-F]{64}$') {
        throw "HP_CODEX_SANDBOX_TRANSITION_EXPECTED_SIGNER_INVALID"
    }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("hoverpocket-codex-sandbox-transition-" + [Guid]::NewGuid().ToString("N"))
    $previousRoot = Join-Path $temporaryRoot "previous"
    $currentRoot = Join-Path $temporaryRoot "current"
    [IO.Directory]::CreateDirectory($previousRoot) | Out-Null
    [IO.Directory]::CreateDirectory($currentRoot) | Out-Null
    $installed = $false
    $previousInstaller = $null
    $currentInstaller = $null
    try {
        $previousRelease = Get-Release -Tag $PreviousTag
        $currentRelease = Get-Release -Tag $CurrentTag
        $previousSnapshot = Get-ReleaseAssetSnapshot -Release $previousRelease
        $currentSnapshot = Get-ReleaseAssetSnapshot -Release $currentRelease
        $previousInstaller = Get-CodexSandboxReleaseInstaller -Release $previousRelease -Snapshot $previousSnapshot -Directory $previousRoot -ExpectedCertificateSha256 $canonicalSigner
        $currentInstaller = Get-CodexSandboxReleaseInstaller -Release $currentRelease -Snapshot $currentSnapshot -Directory $currentRoot -ExpectedCertificateSha256 $canonicalSigner

        Invoke-MsiExec -Arguments @("/i", "`"$($previousInstaller.MsiPath)`"", "/qn", "/norestart") -FailureCode "HP_CODEX_SANDBOX_TRANSITION_INSTALL_FAILED"
        $installed = $true
        Assert-InstalledCodexSandboxHelper -ReleaseInstaller $previousInstaller -ExpectedCertificateSha256 $canonicalSigner

        Invoke-MsiExec -Arguments @("/i", "`"$($currentInstaller.MsiPath)`"", "/qn", "/norestart") -FailureCode "HP_CODEX_SANDBOX_TRANSITION_UPGRADE_FAILED"
        Assert-InstalledCodexSandboxHelper -ReleaseInstaller $currentInstaller -ExpectedCertificateSha256 $canonicalSigner

        Invoke-MsiExec -Arguments @("/x", "`"$($currentInstaller.MsiPath)`"", "/qn", "/norestart") -FailureCode "HP_CODEX_SANDBOX_TRANSITION_ROLLBACK_REMOVE_FAILED"
        $installed = $false
        Invoke-MsiExec -Arguments @("/i", "`"$($previousInstaller.MsiPath)`"", "/qn", "/norestart") -FailureCode "HP_CODEX_SANDBOX_TRANSITION_ROLLBACK_INSTALL_FAILED"
        $installed = $true
        Assert-InstalledCodexSandboxHelper -ReleaseInstaller $previousInstaller -ExpectedCertificateSha256 $canonicalSigner

        Invoke-MsiExec -Arguments @("/x", "`"$($previousInstaller.MsiPath)`"", "/qn", "/norestart") -FailureCode "HP_CODEX_SANDBOX_TRANSITION_UNINSTALL_FAILED"
        $installed = $false
        if ([IO.File]::Exists((Get-CodexSandboxInstalledHelperPath))) {
            throw "HP_CODEX_SANDBOX_TRANSITION_UNINSTALL_READBACK_FAILED"
        }

        Assert-ReleaseMatchesSnapshot -Release (Get-Release -Tag $PreviousTag) -Expected $previousInstaller.Snapshot
        Assert-ReleaseMatchesSnapshot -Release (Get-Release -Tag $CurrentTag) -Expected $currentInstaller.Snapshot
        [ordered]@{
            status = "passed"
            previousTag = $PreviousTag
            currentTag = $CurrentTag
            codexSandboxInstall = "verified"
            codexSandboxUpgrade = "verified"
            codexSandboxRollback = "verified"
            codexSandboxUninstall = "verified"
            publisherAgreement = "same-certificate-verified"
            productionSetupBoundary = "disabled"
        } | ConvertTo-Json -Compress
        return
    }
    finally {
        if ($installed) {
            foreach ($cleanupInstaller in @($currentInstaller, $previousInstaller)) {
                try {
                    if ($null -ne $cleanupInstaller -and [IO.File]::Exists((Get-CodexSandboxInstalledHelperPath))) {
                        Invoke-MsiExec -Arguments @("/x", "`"$($cleanupInstaller.MsiPath)`"", "/qn", "/norestart") -FailureCode "HP_CODEX_SANDBOX_TRANSITION_CLEANUP_FAILED"
                    }
                }
                catch {
                    Write-Warning "Codex sandbox MSI cleanup failed inside the disposable runner."
                }
            }
        }
        if ([IO.Directory]::Exists($temporaryRoot)) {
            [IO.Directory]::Delete($temporaryRoot, $true)
        }
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("hoverpocket-transition-" + [Guid]::NewGuid().ToString("N"))
$downloadRoot = Join-Path $temporaryRoot "downloads"
$previousRoot = Join-Path $downloadRoot "previous"
$currentRoot = Join-Path $downloadRoot "current"
$installRoot = Join-Path $temporaryRoot "install\HoverPocketWin"
[IO.Directory]::CreateDirectory($previousRoot) | Out-Null
[IO.Directory]::CreateDirectory($currentRoot) | Out-Null
$sentinelPath = Join-Path $env:APPDATA ("HoverPocket\an8-transition-" + [Guid]::NewGuid().ToString("N") + ".json")
[IO.Directory]::CreateDirectory((Split-Path -Parent $sentinelPath)) | Out-Null
[IO.File]::WriteAllText($sentinelPath, '{"owner":"an8-transition"}', [Text.UTF8Encoding]::new($false))

try {
    $previousRelease = Get-Release -Tag $PreviousTag
    $currentRelease = Get-Release -Tag $CurrentTag
    $previousSnapshot = Get-ReleaseAssetSnapshot -Release $previousRelease
    $currentSnapshot = Get-ReleaseAssetSnapshot -Release $currentRelease
    $previous = Get-ReleasePackage -Release $previousRelease -Snapshot $previousSnapshot -Directory $previousRoot
    $current = Get-ReleasePackage -Release $currentRelease -Snapshot $currentSnapshot -Directory $currentRoot

    Install-Release -SetupPath $previous.SetupPath -InstallRoot $installRoot -Label "Previous release install"
    $updater = Assert-InstalledVersion -InstallRoot $installRoot -ExpectedVersion $previous.Version

    Apply-Package -UpdaterPath $updater -InstallRoot $installRoot -PackagePath $current.PackagePath -Label "Upgrade"
    $updater = Assert-InstalledVersion -InstallRoot $installRoot -ExpectedVersion $current.Version

    Apply-Package -UpdaterPath $updater -InstallRoot $installRoot -PackagePath $previous.PackagePath -Label "Rollback"
    $updater = Assert-InstalledVersion -InstallRoot $installRoot -ExpectedVersion $previous.Version

    Apply-Package -UpdaterPath $updater -InstallRoot $installRoot -PackagePath $current.PackagePath -Label "Re-upgrade"
    $updater = Assert-InstalledVersion -InstallRoot $installRoot -ExpectedVersion $current.Version

    Invoke-NativeProcess -Path $updater -Arguments @("--silent", "--rootDir", "`"$installRoot`"", "uninstall") -Label "Uninstall"
    if ([IO.Directory]::Exists($installRoot)) {
        throw "Uninstall did not remove the install root."
    }
    if (-not [IO.File]::Exists($sentinelPath)) {
        throw "Uninstall removed user data outside the install root."
    }

    Install-Release -SetupPath $current.SetupPath -InstallRoot $installRoot -Label "Reinstall"
    $updater = Assert-InstalledVersion -InstallRoot $installRoot -ExpectedVersion $current.Version
    if (-not [IO.File]::Exists($sentinelPath)) {
        throw "Reinstall did not preserve user data."
    }

    Assert-ReleaseMatchesSnapshot -Release (Get-Release -Tag $PreviousTag) -Expected $previous.Snapshot
    Assert-ReleaseMatchesSnapshot -Release (Get-Release -Tag $CurrentTag) -Expected $current.Snapshot

    [ordered]@{
        status = "passed"
        previousTag = $PreviousTag
        currentTag = $CurrentTag
        install = "verified"
        upgrade = "verified"
        rollback = "verified"
        uninstall = "verified"
        reinstall = "verified"
        userDataPreserved = $true
        signingMode = $current.SigningMode
    } | ConvertTo-Json -Compress
}
finally {
    if ([IO.File]::Exists($sentinelPath)) {
        [IO.File]::Delete($sentinelPath)
    }
    $updaterPath = Join-Path $installRoot "Update.exe"
    if ([IO.File]::Exists($updaterPath)) {
        try {
            Invoke-NativeProcess -Path $updaterPath -Arguments @("--silent", "--rootDir", "`"$installRoot`"", "uninstall") -Label "Cleanup uninstall"
        }
        catch {
            Write-Warning "Cleanup uninstall failed inside the disposable runner."
        }
    }
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}
