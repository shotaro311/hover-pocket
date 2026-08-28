[CmdletBinding(DefaultParameterSetName = "Check")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Check")]
    [Parameter(Mandatory = $true, ParameterSetName = "Provision")]
    [string]$CodexBin,

    [Parameter(Mandatory = $true, ParameterSetName = "Provision")]
    [switch]$Provision,

    [Parameter(ParameterSetName = "Check")]
    [Parameter(ParameterSetName = "Provision")]
    [string]$CodexHome,

    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")]
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$SupportedVersion = "codex-cli 0.145.0"
$ExpectedExecutableLength = 359245096L
$ExpectedExecutableSha256 = "83751f15cb6a0a7b97df67752c001e3fe1c20e18ffbfec3ff63567296205eb6c"
$ExpectedSetupVersion = 5
$MaximumControlFileBytes = 65536
$ProcessTimeoutSeconds = 120

function Assert-NoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissingLeaf
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($fullPath) -or $fullPath.StartsWith("\\", [StringComparison]::Ordinal)) {
        throw "HP_CODEX_SANDBOX_PATH_INVALID"
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not $root) { throw "HP_CODEX_SANDBOX_PATH_INVALID" }
    $current = $root
    $components = $fullPath.Substring($root.Length).Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)
    for ($index = 0; $index -lt $components.Count; $index += 1) {
        $current = Join-Path $current $components[$index]
        if (-not (Test-Path -LiteralPath $current)) {
            if ($AllowMissingLeaf) { return }
            throw "HP_CODEX_SANDBOX_NOT_READY"
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "HP_CODEX_SANDBOX_PATH_INVALID"
        }
    }
}

function Resolve-TrustedCodexExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePath -Path $fullPath
    $file = Get-Item -LiteralPath $fullPath -Force
    if ($file.PSIsContainer -or $file.Extension -cne ".exe" -or $file.Length -ne $ExpectedExecutableLength) {
        throw "HP_CODEX_SANDBOX_CODEX_UNTRUSTED"
    }
    $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $ExpectedExecutableSha256) {
        throw "HP_CODEX_SANDBOX_CODEX_UNTRUSTED"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
    if (
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false) -cne "OpenAI OpCo, LLC"
    ) {
        throw "HP_CODEX_SANDBOX_CODEX_UNTRUSTED"
    }
    $versionOutput = @(& $fullPath --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or [string]$versionOutput[0] -cne $SupportedVersion) {
        throw "HP_CODEX_SANDBOX_CODEX_UNTRUSTED"
    }
    return $fullPath
}

function Resolve-DedicatedCodexHome {
    param([AllowEmptyString()][string]$ConfiguredPath)

    $localApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
        throw "HP_CODEX_SANDBOX_PATH_INVALID"
    }
    $expected = [IO.Path]::GetFullPath((Join-Path `
        $localApplicationData `
        "HoverPocket\CodexGenerationSandbox\codex-home")).TrimEnd(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $resolved = if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $expected
    }
    else {
        [IO.Path]::GetFullPath($ConfiguredPath).TrimEnd(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    if (-not $resolved.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "HP_CODEX_SANDBOX_PATH_INVALID"
    }
    Assert-NoReparsePath -Path $resolved -AllowMissingLeaf
    return $resolved
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-ControlJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-NoReparsePath -Path $Path
    $file = Get-Item -LiteralPath $Path -Force
    if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt $MaximumControlFileBytes) {
        throw "HP_CODEX_SANDBOX_NOT_READY"
    }
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            return $reader.ReadToEnd() | ConvertFrom-Json
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-Ready {
    param([Parameter(Mandatory = $true)][string]$Home)

    Assert-NoReparsePath -Path $Home
    $marker = Read-ControlJson -Path (Join-Path $Home ".sandbox\setup_marker.json")
    $users = Read-ControlJson -Path (Join-Path $Home ".sandbox-secrets\sandbox_users.json")
    if (
        [int]$marker.version -ne $ExpectedSetupVersion -or
        [string]$marker.offline_username -cne "CodexSandboxOffline" -or
        [string]$marker.online_username -cne "CodexSandboxOnline" -or
        @($marker.proxy_ports).Count -ne 0 -or
        [bool]$marker.allow_local_binding -or
        [int]$users.version -ne $ExpectedSetupVersion -or
        [string]$users.offline.username -cne "CodexSandboxOffline" -or
        [string]::IsNullOrWhiteSpace([string]$users.offline.password) -or
        [string]$users.online.username -cne "CodexSandboxOnline" -or
        [string]::IsNullOrWhiteSpace([string]$users.online.password)
    ) {
        throw "HP_CODEX_SANDBOX_NOT_READY"
    }
}

function Invoke-Provisioning {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Home
    )

    if (-not (Test-IsAdministrator)) {
        throw "HP_CODEX_SANDBOX_ELEVATION_REQUIRED"
    }
    $parent = [IO.Path]::GetDirectoryName($Home)
    [void](New-Item -ItemType Directory -Path $parent -Force)
    Assert-NoReparsePath -Path $parent

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @(
        "sandbox",
        "setup",
        "--elevated",
        "--current-user",
        "--codex-home",
        $Home)) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "HP_CODEX_SANDBOX_PROVISION_FAILED" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            throw "HP_CODEX_SANDBOX_PROVISION_TIMEOUT"
        }
        [void]$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "HP_CODEX_SANDBOX_PROVISION_FAILED"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-SelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) (
        "HoverPocketCodexSandboxProvisionSelfTest-" + [Guid]::NewGuid().ToString("N"))
    $selfTestHome = Join-Path $root "codex-home"
    $sandbox = Join-Path $selfTestHome ".sandbox"
    $secrets = Join-Path $selfTestHome ".sandbox-secrets"
    try {
        [void](New-Item -ItemType Directory -Path $sandbox -Force)
        [void](New-Item -ItemType Directory -Path $secrets -Force)
        [ordered]@{
            version = $ExpectedSetupVersion
            offline_username = "CodexSandboxOffline"
            online_username = "CodexSandboxOnline"
            proxy_ports = @()
            allow_local_binding = $false
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sandbox "setup_marker.json") -Encoding UTF8
        [ordered]@{
            version = $ExpectedSetupVersion
            offline = [ordered]@{
                username = "CodexSandboxOffline"
                password = "fixture-dpapi-blob"
            }
            online = [ordered]@{
                username = "CodexSandboxOnline"
                password = "fixture-dpapi-blob"
            }
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $secrets "sandbox_users.json") -Encoding UTF8
        Assert-Ready -Home $selfTestHome

        $markerPath = Join-Path $sandbox "setup_marker.json"
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $marker.proxy_ports = @(7890)
        $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
        try {
            Assert-Ready -Home $selfTestHome
            throw "SELF_TEST_ACCEPTED_PROXY_DRIFT"
        }
        catch {
            if ($_.Exception.Message -ceq "SELF_TEST_ACCEPTED_PROXY_DRIFT") { throw }
            if ($_.Exception.Message -cne "HP_CODEX_SANDBOX_NOT_READY") {
                throw "SELF_TEST_UNEXPECTED_FAILURE"
            }
        }
        Write-Host "PASS Codex generation sandbox provisioning self-test"
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

try {
    if ($SelfTest) {
        Invoke-SelfTest
        exit 0
    }
    $codex = Resolve-TrustedCodexExecutable -Path $CodexBin
    $dedicatedHome = Resolve-DedicatedCodexHome -ConfiguredPath $CodexHome
    $ready = $false
    try {
        Assert-Ready -Home $dedicatedHome
        $ready = $true
    }
    catch {
        if ($_.Exception.Message -cne "HP_CODEX_SANDBOX_NOT_READY") { throw }
    }
    if (-not $ready) {
        if (-not $Provision) { throw "HP_CODEX_SANDBOX_NOT_READY" }
        Invoke-Provisioning -Executable $codex -Home $dedicatedHome
        Assert-Ready -Home $dedicatedHome
    }

    [ordered]@{
        schemaVersion = 1
        status = "ready"
        codexVersion = $SupportedVersion
        setupVersion = $ExpectedSetupVersion
        dedicatedHome = $true
        runtimeElevationRequired = $false
    } | ConvertTo-Json -Compress
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^HP_CODEX_SANDBOX_[A-Z0-9_]+$') {
        $code = "HP_CODEX_SANDBOX_UNCLASSIFIED"
    }
    Write-Error "FAIL Codex generation sandbox provisioning: $code"
    exit 1
}
