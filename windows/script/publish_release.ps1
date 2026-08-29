[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Project = (Join-Path $PSScriptRoot "..\src\HoverPocket.Shell\HoverPocket.Shell.csproj"),
    [string]$CodexSandboxHelperProject = (Join-Path $PSScriptRoot "..\src\HoverPocket.CodexSandboxSetup\HoverPocket.CodexSandboxSetup.csproj"),
    [string]$CodexSandboxInstallerProject = (Join-Path $PSScriptRoot "..\installer\HoverPocket.CodexSandboxSetup.Installer\HoverPocket.CodexSandboxSetup.Installer.wixproj"),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\..\dist\windows"),
    [string]$PackId = "HoverPocketWin",
    [string]$PackTitle = "HoverPocket",
    [string]$PackAuthors = "Shotaro Matsumoto",
    [string]$ReleaseTag = "",
    [string]$VpkPath = "",
    [string]$SignToolPath = "",
    [string]$NuGetSource = "",
    [switch]$NoRestore,
    [ValidateSet("beta", "formal")]
    [string]$WindowsSigningGate = "beta",
    [string]$SigningCertificateSha1 = "",
    [string]$ExpectedSignerCertificateSha256 = "",
    [string]$TimestampServer = "",
    [switch]$SigningCertificateInMachineStore,
    [switch]$SigningContractTest
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

function Normalize-CertificateFingerprint {
    param(
        [string]$Value,
        [int]$ExpectedLength,
        [string]$Label
    )

    $normalized = ($Value -replace "\s", "").ToLowerInvariant()
    if ($normalized -notmatch "^[0-9a-f]{$ExpectedLength}$") {
        throw "$Label must contain exactly $ExpectedLength hexadecimal characters."
    }

    return $normalized
}

function Resolve-SigningConfiguration {
    param(
        [string]$Gate,
        [string]$CertificateSha1,
        [string]$ExpectedCertificateSha256,
        [string]$TimestampUrl,
        [bool]$UseMachineStore
    )

    if ($Gate -eq "beta") {
        if (-not [string]::IsNullOrWhiteSpace($CertificateSha1) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedCertificateSha256) -or
            -not [string]::IsNullOrWhiteSpace($TimestampUrl) -or
            $UseMachineStore) {
            throw "Signing parameters cannot be combined with WindowsSigningGate=beta."
        }

        return [pscustomobject]@{
            Authenticode = "unsigned"
            SignParameters = ""
            SigningCertificateSha1 = ""
            TimestampServer = ""
            UseMachineStore = $false
            PublisherCertificateSha256 = ""
            ExpectedCertificateSha256 = ""
        }
    }

    $sha1 = Normalize-CertificateFingerprint `
        -Value $CertificateSha1 `
        -ExpectedLength 40 `
        -Label "SigningCertificateSha1"
    $sha256 = Normalize-CertificateFingerprint `
        -Value $ExpectedCertificateSha256 `
        -ExpectedLength 64 `
        -Label "ExpectedSignerCertificateSha256"

    $timestampUri = $null
    if (-not [Uri]::TryCreate($TimestampUrl, [UriKind]::Absolute, [ref]$timestampUri) -or
        $timestampUri.Scheme -ne [Uri]::UriSchemeHttps -or
        -not [string]::IsNullOrWhiteSpace($timestampUri.UserInfo)) {
        throw "TimestampServer must be an absolute HTTPS URL without credentials."
    }

    $arguments = @("/sha1", $sha1)
    if ($UseMachineStore) {
        $arguments += "/sm"
    }
    $arguments += @(
        "/fd", "sha256",
        "/td", "sha256",
        "/tr", $timestampUri.AbsoluteUri
    )

    return [pscustomobject]@{
        Authenticode = "signed-timestamped-verified"
        SignParameters = ($arguments -join " ")
        SigningCertificateSha1 = $sha1
        TimestampServer = $timestampUri.AbsoluteUri
        UseMachineStore = $UseMachineStore
        PublisherCertificateSha256 = $sha256
        ExpectedCertificateSha256 = $sha256
    }
}

function Resolve-SignToolPath {
    param([string]$Candidate)

    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        $resolved = (Resolve-Path -LiteralPath $Candidate -ErrorAction Stop).Path
        $item = Get-Item -LiteralPath $resolved -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Signing tool path must be a regular non-reparse file."
        }
        return $item.FullName
    }

    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }
    $command = Get-Command signtool -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }
    throw "Formal Windows release requires signtool.exe. Pass -SignToolPath when it is not on PATH."
}

function Invoke-AuthenticodeSign {
    param(
        [string]$SignTool,
        [string]$Path,
        $SigningConfiguration,
        [string]$Label
    )

    $arguments = @("sign", "/sha1", $SigningConfiguration.SigningCertificateSha1)
    if ($SigningConfiguration.UseMachineStore) {
        $arguments += "/sm"
    }
    $arguments += @(
        "/fd", "sha256",
        "/td", "sha256",
        "/tr", $SigningConfiguration.TimestampServer,
        $Path
    )
    & $SignTool @arguments *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "$Label signing failed."
    }
}

function Get-CodexSandboxMsiAssetName {
    param([string]$Version)

    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Codex sandbox MSI version must be MAJOR.MINOR.PATCH."
    }
    return "HoverPocket.CodexSandboxSetup-$Version-win-x64.msi"
}

function Get-CertificateSha256 {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    if ($null -eq $Certificate) {
        throw "Signer certificate is missing."
    }

    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($hasher.ComputeHash($Certificate.RawData) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $hasher.Dispose()
    }
}

function Assert-TimestampedAuthenticode {
    param(
        [string]$Path,
        [string]$Label,
        [string]$ExpectedCertificateSha256
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "$Label Authenticode status is $($signature.Status)."
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        throw "$Label is not signed with a timestamped Authenticode signature."
    }

    $certificateSha256 = Get-CertificateSha256 -Certificate $signature.SignerCertificate
    if ($certificateSha256 -ne $ExpectedCertificateSha256) {
        throw "$Label signer certificate does not match ExpectedSignerCertificateSha256."
    }

    return $certificateSha256
}

function Get-SingleReleaseAsset {
    param(
        [string]$Directory,
        [string]$Filter,
        [string]$Label
    )

    $matches = @(Get-ChildItem -LiteralPath $Directory -File -Filter $Filter)
    if ($matches.Count -ne 1) {
        throw "$Label must resolve to exactly one release asset."
    }

    return $matches[0].FullName
}

function Assert-CleanOutputDirectory {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw "$Label output path exists and is not a directory."
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label output directory must not be a reparse point."
    }
    if ($null -ne (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) {
        throw "$Label output directory must be empty. Use a fresh OutputRoot for every release attempt."
    }
}

function Get-SinglePackagedExecutable {
    param(
        [string]$ArchivePath,
        [string]$MainExecutable,
        [string]$Destination,
        [string]$Label
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
    $matches = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter $MainExecutable)
    if ($matches.Count -ne 1) {
        throw "$Label must contain exactly one $MainExecutable."
    }

    return $matches[0].FullName
}

function Assert-FormalReleaseSignatures {
    param(
        [string]$Directory,
        [string]$PackageId,
        [string]$PackageVersion,
        [string]$MainExecutable,
        [string]$CodexSandboxHelperPath,
        [string]$CodexSandboxMsiPath,
        [string]$ExpectedCertificateSha256
    )

    $setupPath = Get-SingleReleaseAsset `
        -Directory $Directory `
        -Filter "$PackageId-*-Setup.exe" `
        -Label "Setup"
    $portablePath = Get-SingleReleaseAsset `
        -Directory $Directory `
        -Filter "$PackageId-*-Portable.zip" `
        -Label "Portable"
    $fullPackagePath = Get-SingleReleaseAsset `
        -Directory $Directory `
        -Filter "$PackageId-$PackageVersion-full.nupkg" `
        -Label "Full package"

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hoverpocket-signature-readback-" + [Guid]::NewGuid().ToString("N"))
    $portableRoot = Join-Path $temporaryRoot "portable"
    $packageRoot = Join-Path $temporaryRoot "package"
    New-Item -ItemType Directory -Path $portableRoot, $packageRoot | Out-Null

    try {
        $portableExecutable = Get-SinglePackagedExecutable `
            -ArchivePath $portablePath `
            -MainExecutable $MainExecutable `
            -Destination $portableRoot `
            -Label "Portable"
        $packageExecutable = Get-SinglePackagedExecutable `
            -ArchivePath $fullPackagePath `
            -MainExecutable $MainExecutable `
            -Destination $packageRoot `
            -Label "Full package"

        $certificateHashes = @(
            Assert-TimestampedAuthenticode `
                -Path $setupPath `
                -Label "Setup" `
                -ExpectedCertificateSha256 $ExpectedCertificateSha256
            Assert-TimestampedAuthenticode `
                -Path $portableExecutable `
                -Label "Portable application" `
                -ExpectedCertificateSha256 $ExpectedCertificateSha256
            Assert-TimestampedAuthenticode `
                -Path $packageExecutable `
                -Label "Full package application" `
                -ExpectedCertificateSha256 $ExpectedCertificateSha256
            Assert-TimestampedAuthenticode `
                -Path $CodexSandboxHelperPath `
                -Label "Codex sandbox helper" `
                -ExpectedCertificateSha256 $ExpectedCertificateSha256
            Assert-TimestampedAuthenticode `
                -Path $CodexSandboxMsiPath `
                -Label "Codex sandbox MSI" `
                -ExpectedCertificateSha256 $ExpectedCertificateSha256
        )
        if (@($certificateHashes | Sort-Object -Unique).Count -ne 1) {
            throw "Shell/Velopack artifacts, Codex sandbox helper, and Codex sandbox MSI use different signer certificates."
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SigningContractTest {
    $beta = Resolve-SigningConfiguration `
        -Gate "beta" `
        -CertificateSha1 "" `
        -ExpectedCertificateSha256 "" `
        -TimestampUrl "" `
        -UseMachineStore $false
    if ($beta.Authenticode -ne "unsigned" -or
        -not [string]::IsNullOrEmpty($beta.SignParameters) -or
        -not [string]::IsNullOrEmpty($beta.PublisherCertificateSha256)) {
        throw "Unsigned beta signing contract is invalid."
    }

    $formal = Resolve-SigningConfiguration `
        -Gate "formal" `
        -CertificateSha1 ("a" * 40) `
        -ExpectedCertificateSha256 ("b" * 64) `
        -TimestampUrl "https://timestamp.example.test" `
        -UseMachineStore $true
    if ($formal.Authenticode -ne "signed-timestamped-verified" -or
        $formal.SignParameters -ne ("/sha1 " + ("a" * 40) + " /sm /fd sha256 /td sha256 /tr https://timestamp.example.test/") -or
        $formal.PublisherCertificateSha256 -cne ("b" * 64) -or
        (Get-CodexSandboxMsiAssetName -Version "1.2.3") -cne "HoverPocket.CodexSandboxSetup-1.2.3-win-x64.msi") {
        throw "Formal signing arguments are not deterministic."
    }

    $missingSignTool = Join-Path ([System.IO.Path]::GetTempPath()) ("hoverpocket-missing-signtool-" + [Guid]::NewGuid().ToString("N") + ".exe")
    $invalidCases = @(
        { Resolve-SignToolPath -Candidate $missingSignTool },
        { Resolve-SigningConfiguration -Gate "beta" -CertificateSha1 ("a" * 40) -ExpectedCertificateSha256 "" -TimestampUrl "" -UseMachineStore $false },
        { Resolve-SigningConfiguration -Gate "formal" -CertificateSha1 "invalid" -ExpectedCertificateSha256 ("b" * 64) -TimestampUrl "https://timestamp.example.test" -UseMachineStore $false },
        { Resolve-SigningConfiguration -Gate "formal" -CertificateSha1 ("a" * 40) -ExpectedCertificateSha256 "invalid" -TimestampUrl "https://timestamp.example.test" -UseMachineStore $false },
        { Resolve-SigningConfiguration -Gate "formal" -CertificateSha1 ("a" * 40) -ExpectedCertificateSha256 ("b" * 64) -TimestampUrl "http://timestamp.example.test" -UseMachineStore $false },
        { Resolve-SigningConfiguration -Gate "formal" -CertificateSha1 ("a" * 40) -ExpectedCertificateSha256 ("b" * 64) -TimestampUrl "https://user:password@timestamp.example.test" -UseMachineStore $false }
    )
    foreach ($invalidCase in $invalidCases) {
        $failedClosed = $false
        try {
            & $invalidCase | Out-Null
        }
        catch {
            $failedClosed = $true
        }
        if (-not $failedClosed) {
            throw "Invalid signing configuration did not fail closed."
        }
    }

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hoverpocket-signing-contract-" + [Guid]::NewGuid().ToString("N"))
    $cleanDirectory = Join-Path $temporaryRoot "clean"
    New-Item -ItemType Directory -Path $cleanDirectory | Out-Null
    try {
        Assert-CleanOutputDirectory -Path (Join-Path $temporaryRoot "missing") -Label "Missing"
        Assert-CleanOutputDirectory -Path $cleanDirectory -Label "Clean"
        [System.IO.File]::WriteAllText((Join-Path $cleanDirectory "stale-payload.dll"), "stale")
        $failedClosed = $false
        try {
            Assert-CleanOutputDirectory -Path $cleanDirectory -Label "Non-empty"
        }
        catch {
            $failedClosed = $true
        }
        if (-not $failedClosed) {
            throw "Non-empty release output did not fail closed."
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Output "windows_release_signing_contract_verify=ok"
}

if ($SigningContractTest) {
    Invoke-SigningContractTest
    exit 0
}

$signingConfiguration = Resolve-SigningConfiguration `
    -Gate $WindowsSigningGate `
    -CertificateSha1 $SigningCertificateSha1 `
    -ExpectedCertificateSha256 $ExpectedSignerCertificateSha256 `
    -TimestampUrl $TimestampServer `
    -UseMachineStore $SigningCertificateInMachineStore.IsPresent
$signTool = $null
if ($WindowsSigningGate -eq "formal") {
    $signTool = Resolve-SignToolPath -Candidate $SignToolPath
}

$projectPath = (Resolve-Path -LiteralPath $Project).Path
$codexSandboxHelperProjectPath = $null
$codexSandboxInstallerProjectPath = $null
$codexSandboxInstallerVerifierPath = $null
if ($WindowsSigningGate -eq "formal") {
    $codexSandboxHelperProjectPath = (Resolve-Path -LiteralPath $CodexSandboxHelperProject).Path
    $codexSandboxInstallerProjectPath = (Resolve-Path -LiteralPath $CodexSandboxInstallerProject).Path
    $codexSandboxInstallerVerifierPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "verify_codex_sandbox_installer.ps1")).Path
}
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
$codexSandboxHelperPublishDir = Join-Path $outputRootPath "codex-sandbox-helper\publish\$Runtime\$version"
$codexSandboxInstallerOutputDir = Join-Path $outputRootPath "codex-sandbox-helper\installer\$version"
Assert-CleanOutputDirectory -Path $publishDir -Label "Publish"
Assert-CleanOutputDirectory -Path $releaseDir -Label "Release"
if ($WindowsSigningGate -eq "formal") {
    Assert-CleanOutputDirectory -Path $codexSandboxHelperPublishDir -Label "Codex sandbox helper publish"
    Assert-CleanOutputDirectory -Path $codexSandboxInstallerOutputDir -Label "Codex sandbox installer"
    New-Item -ItemType Directory -Force -Path $publishDir, $releaseDir, $codexSandboxHelperPublishDir, $codexSandboxInstallerOutputDir | Out-Null
}
else {
    New-Item -ItemType Directory -Force -Path $publishDir, $releaseDir | Out-Null
}
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

if ($WindowsSigningGate -eq "formal") {
    $publishArgs += "-p:HoverPocketPublisherCertificateSha256=$($signingConfiguration.PublisherCertificateSha256)"
}

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

$codexSandboxHelperPath = $null
$codexSandboxMsiPath = $null
$codexSandboxMsiAssetName = $null
$codexSandboxHelperMetadata = $null
$codexSandboxMsiMetadata = $null
if ($WindowsSigningGate -eq "formal") {
    $helperPublishArgs = @(
        "publish",
        $codexSandboxHelperProjectPath,
        "--configuration", $Configuration,
        "--runtime", $Runtime,
        "--self-contained", "true",
        "--output", $codexSandboxHelperPublishDir,
        "--nologo",
        "-p:PublishSingleFile=false",
        "-p:DebugSymbols=false",
        "-p:DebugType=None",
        "-p:Version=$version",
        "-p:HoverPocketPublisherCertificateSha256=$($signingConfiguration.PublisherCertificateSha256)",
        "-p:NuGetAudit=false"
    )
    if ($NoRestore) {
        $helperPublishArgs += "--no-restore"
    }
    if (-not [string]::IsNullOrWhiteSpace($NuGetSource)) {
        $helperPublishArgs += @("--source", $NuGetSource, "--ignore-failed-sources")
    }
    Write-Host "Publishing dormant Codex sandbox helper for signed MSI harvest..."
    & dotnet @helperPublishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Codex sandbox helper publish failed."
    }
    $codexSandboxHelperPath = Join-Path $codexSandboxHelperPublishDir "HoverPocket.CodexSandboxSetup.exe"
    if (-not [IO.File]::Exists($codexSandboxHelperPath)) {
        throw "Codex sandbox helper artifact is missing before signing."
    }
    Invoke-AuthenticodeSign `
        -SignTool $signTool `
        -Path $codexSandboxHelperPath `
        -SigningConfiguration $signingConfiguration `
        -Label "Codex sandbox helper"
    [void](Assert-TimestampedAuthenticode `
        -Path $codexSandboxHelperPath `
        -Label "Codex sandbox helper" `
        -ExpectedCertificateSha256 $signingConfiguration.ExpectedCertificateSha256)

    $installerBuildArgs = @(
        "build",
        $codexSandboxInstallerProjectPath,
        "--configuration", $Configuration,
        "--output", $codexSandboxInstallerOutputDir,
        "--nologo",
        "-p:InstallerPlatform=x64",
        "-p:ProductVersion=$version",
        "-p:HelperPublishDir=$codexSandboxHelperPublishDir",
        "-p:NuGetAudit=false"
    )
    if ($NoRestore) {
        $installerBuildArgs += "--no-restore"
    }
    if (-not [string]::IsNullOrWhiteSpace($NuGetSource)) {
        $installerBuildArgs += @("--source", $NuGetSource, "--ignore-failed-sources")
    }
    Write-Host "Building dedicated per-machine Codex sandbox MSI from the signed helper payload..."
    & dotnet @installerBuildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Codex sandbox MSI build failed."
    }
    $msiFiles = @(Get-ChildItem -LiteralPath $codexSandboxInstallerOutputDir -Filter *.msi -File)
    if ($msiFiles.Count -ne 1) {
        throw "Codex sandbox installer output must contain exactly one MSI."
    }
    $codexSandboxMsiPath = $msiFiles[0].FullName
    Invoke-AuthenticodeSign `
        -SignTool $signTool `
        -Path $codexSandboxMsiPath `
        -SigningConfiguration $signingConfiguration `
        -Label "Codex sandbox MSI"
    [void](Assert-TimestampedAuthenticode `
        -Path $codexSandboxMsiPath `
        -Label "Codex sandbox MSI" `
        -ExpectedCertificateSha256 $signingConfiguration.ExpectedCertificateSha256)
    & $codexSandboxInstallerVerifierPath `
        -MsiPath $codexSandboxMsiPath `
        -ExpectedProductVersion $version `
        -ExpectedUpgradeCode "{9E28ABD6-A496-472E-98AB-AE8D70C27B48}" | Out-Null

    $codexSandboxHelperFile = Get-Item -LiteralPath $codexSandboxHelperPath
    $codexSandboxHelperMetadata = [ordered]@{
        fileName = $codexSandboxHelperFile.Name
        size = $codexSandboxHelperFile.Length
        sha256 = (Get-FileHash -LiteralPath $codexSandboxHelperPath -Algorithm SHA256).Hash.ToLowerInvariant()
        authenticode = "signed-timestamped-verified"
        timestamp = "verified"
    }
    $codexSandboxMsiAssetName = Get-CodexSandboxMsiAssetName -Version $version
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

if ($WindowsSigningGate -eq "formal") {
    $packArgs += @("--signParams", $signingConfiguration.SignParameters)
}

Write-Host "Packing Velopack assets..."
& $vpk @packArgs
if ($LASTEXITCODE -ne 0) {
    throw "vpk pack failed with exit code $LASTEXITCODE."
}

if ($WindowsSigningGate -eq "formal") {
    $codexSandboxPublishedMsiPath = Join-Path $releaseDir $codexSandboxMsiAssetName
    [IO.File]::Copy($codexSandboxMsiPath, $codexSandboxPublishedMsiPath, $false)
    $codexSandboxMsiFile = Get-Item -LiteralPath $codexSandboxPublishedMsiPath
    $codexSandboxMsiMetadata = [ordered]@{
        assetName = $codexSandboxMsiAssetName
        assetSize = $codexSandboxMsiFile.Length
        assetSha256 = (Get-FileHash -LiteralPath $codexSandboxPublishedMsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-Host "Verifying timestamped Authenticode and same-publisher agreement without printing certificate identifiers..."
    Assert-FormalReleaseSignatures `
        -Directory $releaseDir `
        -PackageId $PackId `
        -PackageVersion $version `
        -MainExecutable $mainExe `
        -CodexSandboxHelperPath $codexSandboxHelperPath `
        -CodexSandboxMsiPath $codexSandboxPublishedMsiPath `
        -ExpectedCertificateSha256 $signingConfiguration.ExpectedCertificateSha256
}

$releaseManifestPath = Join-Path $releaseDir "release-manifest.win.json"
$codexSandboxManifest = [ordered]@{
    published = $false
    trustedProductionSetupBoundary = $false
    productionSetupAvailable = $false
    productionGenerationAvailable = $false
    productionActivationAvailable = $false
}
if ($WindowsSigningGate -eq "formal") {
    $codexSandboxManifest.published = $true
    $codexSandboxManifest.assetName = $codexSandboxMsiMetadata.assetName
    $codexSandboxManifest.assetSize = $codexSandboxMsiMetadata.assetSize
    $codexSandboxManifest.assetSha256 = $codexSandboxMsiMetadata.assetSha256
    $codexSandboxManifest.msiAuthenticode = "signed-timestamped-verified"
    $codexSandboxManifest.msiTimestamp = "verified"
    $codexSandboxManifest.embeddedHelper = $codexSandboxHelperMetadata
    $codexSandboxManifest.publisherAgreement = "shell-helper-msi-same-certificate"
    $codexSandboxManifest.signerCertificateSha256 = $signingConfiguration.ExpectedCertificateSha256
}

$releaseManifest = [ordered]@{
    schemaVersion = 2
    product = "HoverPocket"
    packageId = $PackId
    version = $version
    runtime = $Runtime
    updateChannel = "win"
    updateFeed = "releases.win.json"
    oauthMetadata = "embedded-and-verified"
    authenticode = $signingConfiguration.Authenticode
    codexSandboxSetup = $codexSandboxManifest
}
$releaseManifestJson = $releaseManifest | ConvertTo-Json -Depth 5
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
