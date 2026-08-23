[CmdletBinding()]
param(
    [string]$Repository = "shotaro311/hover-pocket",
    [Parameter(Mandatory = $true)][string]$PreviousTag,
    [Parameter(Mandatory = $true)][string]$CurrentTag,
    [switch]$AllowUnsignedBeta
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

function Get-ReleasePackage {
    param($Release, [string]$Directory)

    $manifestPath = Save-ReleaseAsset -Release $Release -Name "release-manifest.win.json" -Directory $Directory
    $checksumPath = Save-ReleaseAsset -Release $Release -Name "SHA256SUMS-win.txt" -Directory $Directory
    $feedPath = Save-ReleaseAsset -Release $Release -Name "releases.win.json" -Directory $Directory
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $feed = Get-Content -LiteralPath $feedPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne "HoverPocket" -or $manifest.packageId -ne "HoverPocketWin") {
        throw "Release manifest identity is invalid."
    }
    if ($Release.tag_name -ne "win-v$($manifest.version)") {
        throw "Release tag and manifest version differ."
    }
    $isUnsignedBeta = $manifest.authenticode -eq "unsigned"
    if ($isUnsignedBeta) {
        if (-not $AllowUnsignedBeta) { throw "Unsigned release execution requires AllowUnsignedBeta." }
    }
    elseif ($manifest.authenticode -ne "signed-timestamped-verified") {
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

    if (-not $isUnsignedBeta) {
        $signature = Get-AuthenticodeSignature -LiteralPath $setupPath
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.TimeStamperCertificate) {
            throw "Setup does not have a valid timestamped Authenticode signature."
        }
    }
    return [pscustomobject]@{
        Version = [string]$manifest.version
        SetupPath = $setupPath
        PackagePath = $packagePath
        Authenticode = [string]$manifest.authenticode
        SigningMode = if ($isUnsignedBeta) { "explicit-beta" } else { "formal" }
    }
}

function Invoke-NativeProcess {
    param([string]$Path, [string[]]$Arguments, [string]$Label)

    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "$Label failed with exit code $($process.ExitCode)."
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
        $verificationOutput = @(& $applicationPath --verify release-config)
        if ($LASTEXITCODE -ne 0) {
            throw "Installed release-config verifier failed."
        }
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

if ($PreviousTag -eq $CurrentTag) {
    throw "PreviousTag and CurrentTag must differ."
}
$previousVersion = [version]$PreviousTag.Substring(5)
$currentVersion = [version]$CurrentTag.Substring(5)
if ($previousVersion -ge $currentVersion) {
    throw "PreviousTag must be older than CurrentTag."
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
    $previous = Get-ReleasePackage -Release (Get-Release -Tag $PreviousTag) -Directory $previousRoot
    $current = Get-ReleasePackage -Release (Get-Release -Tag $CurrentTag) -Directory $currentRoot

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
