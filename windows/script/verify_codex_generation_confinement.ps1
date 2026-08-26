[CmdletBinding(DefaultParameterSetName = "Canary")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Canary")]
    [string]$CodexBin,

    [Parameter(ParameterSetName = "Canary")]
    [ValidateSet("elevated", "unelevated")]
    [string]$SandboxImplementation = "elevated",

    [Parameter(ParameterSetName = "Canary")]
    [switch]$ExpectUnelevatedReadOnlyRejection,

    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")]
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$SupportedVersion = "codex-cli 0.145.0"
$ExpectedExecutableLength = 359245096L
$ExpectedExecutableSha256 = "83751f15cb6a0a7b97df67752c001e3fe1c20e18ffbfec3ff63567296205eb6c"
$RootPrefix = "HoverPocketCodexConfinement-"
$ForeignPrefix = "HoverPocketCodexForeign-"
$MaximumStdoutCharacters = 16384
$MaximumStderrCharacters = 32768
$UnelevatedReadOnlyRejection = "windows sandbox failed: Restricted read-only access requires the elevated Windows sandbox backend"
$ExpectedProbe = [ordered]@{
    codex_home_read = $false
    foreign_read = $false
    network_connected = $false
    user_home_read = $false
    workspace_read = $true
    workspace_write = $false
}

$ProbeScript = @'
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$UserHome,
    [Parameter(Mandatory = $true)][string]$ForeignRoot,
    [Parameter(Mandatory = $true)][int]$Port
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-Readable {
    param([string]$Path)
    try {
        [void][IO.File]::ReadAllBytes($Path)
        return $true
    }
    catch {
        return $false
    }
}

function Test-Writable {
    param([string]$Path)
    try {
        [IO.File]::WriteAllText($Path, "write-canary", [Text.Encoding]::UTF8)
        return $true
    }
    catch {
        return $false
    }
}

$networkConnected = $false
$client = [Net.Sockets.TcpClient]::new()
try {
    $connectTask = $client.ConnectAsync("127.0.0.1", $Port)
    if ($connectTask.Wait(1000) -and $client.Connected) {
        $networkConnected = $true
    }
}
catch {
    $networkConnected = $false
}
finally {
    $client.Dispose()
}

[ordered]@{
    codex_home_read = Test-Readable (Join-Path $CodexHome "denied.txt")
    foreign_read = Test-Readable (Join-Path $ForeignRoot "denied.txt")
    network_connected = $networkConnected
    user_home_read = Test-Readable (Join-Path $UserHome "denied.txt")
    workspace_read = Test-Readable (Join-Path $Workspace "allowed.txt")
    workspace_write = Test-Writable (Join-Path $Workspace "write-attempt.txt")
} | ConvertTo-Json -Compress
'@

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.IndexOfAny([char[]](0..31)) -ge 0) {
        throw "A confinement value contains a control character."
    }
    return ($Value | ConvertTo-Json -Compress)
}

function Get-ConfinementArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$UserHome,
        [Parameter(Mandatory = $true)][string]$Implementation,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ProbePath,
        [Parameter(Mandatory = $true)][string]$ForeignRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $workspacePath = [IO.Path]::GetFullPath($Workspace)
    $codexHomePath = [IO.Path]::GetFullPath($CodexHome)
    $userHomePath = [IO.Path]::GetFullPath($UserHome)
    $parentPaths = @(
        [IO.Path]::GetDirectoryName($workspacePath)
        [IO.Path]::GetDirectoryName($codexHomePath)
        [IO.Path]::GetDirectoryName($userHomePath)
    ) | Select-Object -Unique
    $rootPaths = @($workspacePath, $codexHomePath, $userHomePath) | Select-Object -Unique
    if (@($parentPaths).Count -ne 1 -or @($rootPaths).Count -ne 3) {
        throw "Confinement roots must be distinct siblings."
    }

    $filesystem = "permissions.hoverpocket-generation.filesystem={" +
        "$(ConvertTo-TomlString ':minimal')=`"read`"," +
        "$(ConvertTo-TomlString $workspacePath)=`"read`"," +
        "$(ConvertTo-TomlString $codexHomePath)=`"deny`"," +
        "$(ConvertTo-TomlString $userHomePath)=`"deny`"}"
    $windowsDirectory = [IO.Path]::GetFullPath($env:SystemRoot)
    $systemPath = [string]::Join(
        [IO.Path]::PathSeparator,
        @((Join-Path $windowsDirectory "System32"), $windowsDirectory))
    $commandShell = Join-Path $windowsDirectory "System32\cmd.exe"
    $shellEnvironment = "shell_environment_policy.set={" +
        "PATH=$(ConvertTo-TomlString $systemPath)," +
        "LANG=`"C`"," +
        "SYSTEMROOT=$(ConvertTo-TomlString $windowsDirectory)," +
        "WINDIR=$(ConvertTo-TomlString $windowsDirectory)," +
        "COMSPEC=$(ConvertTo-TomlString $commandShell)}"

    return @(
        "sandbox"
        "-P", "hoverpocket-generation"
        "-c", "windows.sandbox=`"$Implementation`""
        "-c", 'approval_policy="never"'
        "-c", 'default_permissions="hoverpocket-generation"'
        "-c", $filesystem
        "-c", "permissions.hoverpocket-generation.network.enabled=false"
        "-c", 'shell_environment_policy.inherit="none"'
        "-c", $shellEnvironment
        "-C", $workspacePath
        $PowerShellPath
        "-NoLogo"
        "-NoProfile"
        "-NonInteractive"
        "-ExecutionPolicy", "Bypass"
        "-File", $ProbePath
        "-Workspace", $workspacePath
        "-CodexHome", $codexHomePath
        "-UserHome", $userHomePath
        "-ForeignRoot", [IO.Path]::GetFullPath($ForeignRoot)
        "-Port", [string]$Port
    )
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($fullPath) -or $fullPath.StartsWith("\\", [StringComparison]::Ordinal)) {
        throw "The pinned Codex path is not a local absolute path."
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not $root) {
        throw "The pinned Codex path has no local root."
    }
    $current = $root
    $relative = $fullPath.Substring($root.Length)
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($component in $relative.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The pinned Codex path contains a reparse point."
        }
    }
}

function Resolve-TrustedCodexExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePath -Path $fullPath
    $file = Get-Item -LiteralPath $fullPath -Force
    if ($file.PSIsContainer -or $file.Extension -cne ".exe" -or $file.Length -ne $ExpectedExecutableLength) {
        throw "The pinned Codex executable shape is invalid."
    }
    $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $ExpectedExecutableSha256) {
        throw "The pinned Codex executable hash is invalid."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
    if (
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false) -cne "OpenAI OpCo, LLC"
    ) {
        throw "The pinned Codex executable signature is invalid."
    }

    $versionOutput = @(& $fullPath --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or [string]$versionOutput[0] -cne $SupportedVersion) {
        throw "The pinned Codex executable version is unsupported."
    }
    return $fullPath
}

function ConvertFrom-ProbeOutput {
    param([Parameter(Mandatory = $true)][string]$Output)

    if ($Output.Length -gt $MaximumStdoutCharacters) {
        throw "Sandbox probe stdout exceeded its limit."
    }
    $lines = @($Output -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -ne 1) {
        throw "Sandbox probe emitted unexpected additional output."
    }
    try {
        $payload = $lines[0] | ConvertFrom-Json
    }
    catch {
        throw "Sandbox probe output could not be decoded."
    }
    $actualNames = @($payload.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @($ExpectedProbe.Keys | Sort-Object)
    if ([string]::Join("`n", $actualNames) -cne [string]::Join("`n", $expectedNames)) {
        throw "Sandbox probe output keys differ from the contract."
    }
    foreach ($entry in $ExpectedProbe.GetEnumerator()) {
        $value = $payload.PSObject.Properties[$entry.Key].Value
        if ($value -isnot [bool] -or $value -ne $entry.Value) {
            throw "Sandbox probe did not enforce the exact file and network boundary."
        }
    }
    return $payload
}

function Test-ExpectedUnelevatedRejection {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Stdout,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Stderr
    )

    return [string]::IsNullOrWhiteSpace($Stdout) -and $Stderr.Trim() -ceq $UnelevatedReadOnlyRejection
}

function Invoke-BoundedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][System.Collections.Generic.IDictionary[string, string]]$Environment,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $start.Environment.Clear()
    foreach ($entry in $Environment.GetEnumerator()) {
        $start.Environment[$entry.Key] = $entry.Value
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw "Sandbox probe process did not start."
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 50
        }
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { }
            throw "Sandbox probe timed out."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-SanitizedDiagnostic {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$SensitiveValues
    )

    $sanitized = $Text
    foreach ($value in $SensitiveValues) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $sanitized = $sanitized.Replace($value, "<path>", [StringComparison]::OrdinalIgnoreCase)
        }
    }
    foreach ($marker in @("allowed-canary", "codex-home-canary", "outside-root-canary", "write-canary")) {
        $sanitized = $sanitized.Replace($marker, "<canary>", [StringComparison]::Ordinal)
    }
    $sanitized = [Text.RegularExpressions.Regex]::Replace($sanitized, '(?i)\b[0-9a-f]{32}\b', '<id>')
    $sanitized = [Text.RegularExpressions.Regex]::Replace($sanitized, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    if ($sanitized.Length -gt 1600) {
        $sanitized = $sanitized.Substring(0, 1600) + "<truncated>"
    }
    if ([string]::IsNullOrWhiteSpace($sanitized)) { return "<empty>" }
    return $sanitized.Trim()
}

function Remove-ValidatedTemporaryRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TemporaryRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedPrefix
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (
        -not $parent.Equals([IO.Path]::GetFullPath($TemporaryRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($fullPath).StartsWith($ExpectedPrefix, [StringComparison]::Ordinal) -or
        ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Temporary confinement root failed cleanup validation."
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Invoke-SelfTest {
    $valid = [ordered]@{}
    foreach ($entry in $ExpectedProbe.GetEnumerator()) { $valid[$entry.Key] = $entry.Value }
    [void](ConvertFrom-ProbeOutput (($valid | ConvertTo-Json -Compress) + "`n"))
    foreach ($key in $ExpectedProbe.Keys) {
        $invalid = [ordered]@{}
        foreach ($entry in $ExpectedProbe.GetEnumerator()) { $invalid[$entry.Key] = $entry.Value }
        $invalid[$key] = -not [bool]$invalid[$key]
        try {
            [void](ConvertFrom-ProbeOutput ($invalid | ConvertTo-Json -Compress))
            throw "Self-test accepted an invalid $key result."
        }
        catch {
            if ($_.Exception.Message -like "Self-test accepted*") { throw }
        }
    }
    if (
        -not (Test-ExpectedUnelevatedRejection -Stdout "" -Stderr ($UnelevatedReadOnlyRejection + "`r`n")) -or
        (Test-ExpectedUnelevatedRejection -Stdout "unexpected" -Stderr $UnelevatedReadOnlyRejection) -or
        (Test-ExpectedUnelevatedRejection -Stdout "" -Stderr "another failure")
    ) {
        throw "Self-test unelevated rejection contract failed."
    }

    $oldSystemRoot = $env:SystemRoot
    try {
        $env:SystemRoot = "C:\Windows"
        $arguments = Get-ConfinementArguments `
            -Workspace "C:\fixture\workspace" `
            -CodexHome "C:\fixture\codex-home" `
            -UserHome "C:\fixture\user-home" `
            -Implementation "unelevated" `
            -PowerShellPath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ProbePath "C:\fixture\workspace\probe.ps1" `
            -ForeignRoot "C:\foreign" `
            -Port 12345
        $joined = [string]::Join("`n", $arguments)
        $required = @(
            'windows.sandbox="unelevated"'
            'default_permissions="hoverpocket-generation"'
            '"C:\\fixture\\workspace"="read"'
            '"C:\\fixture\\codex-home"="deny"'
            '"C:\\fixture\\user-home"="deny"'
            'network.enabled=false'
            'shell_environment_policy.inherit="none"'
            'SYSTEMROOT="C:\\Windows"'
        )
        foreach ($marker in $required) {
            if (-not $joined.Contains($marker, [StringComparison]::Ordinal)) {
                throw "Self-test confinement arguments differ from the expected contract."
            }
        }
    }
    finally {
        $env:SystemRoot = $oldSystemRoot
    }
    Write-Host "PASS Codex generation confinement verifier self-test"
}

function Invoke-Canary {
    if ($ExpectUnelevatedReadOnlyRejection -and $SandboxImplementation -cne "unelevated") {
        throw "The unelevated rejection expectation requires the unelevated implementation."
    }
    $codex = Resolve-TrustedCodexExecutable -Path $CodexBin
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $root = Join-Path $temporaryRoot ($RootPrefix + [Guid]::NewGuid().ToString("N"))
    $foreignRoot = Join-Path $temporaryRoot ($ForeignPrefix + [Guid]::NewGuid().ToString("N"))
    $listener = $null
    try {
        $workspace = Join-Path $root "workspace"
        $codexHome = Join-Path $root "codex-home"
        $userHome = Join-Path $root "user-home"
        $localAppData = Join-Path $userHome "AppData\Local"
        $roamingAppData = Join-Path $userHome "AppData\Roaming"
        $processTemp = Join-Path $root "tmp"
        foreach ($directory in @($workspace, $codexHome, $userHome, $localAppData, $roamingAppData, $processTemp, $foreignRoot)) {
            [void](New-Item -ItemType Directory -Path $directory)
        }
        [IO.File]::WriteAllText((Join-Path $workspace "allowed.txt"), "allowed-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $codexHome "denied.txt"), "codex-home-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $userHome "denied.txt"), "user-home-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $foreignRoot "denied.txt"), "outside-root-canary", [Text.Encoding]::UTF8)
        $probePath = Join-Path $workspace "probe.ps1"
        [IO.File]::WriteAllText($probePath, $ProbeScript, [Text.UTF8Encoding]::new($false))

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start(1)
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $acceptTask = $listener.AcceptTcpClientAsync()
        $windowsDirectory = [IO.Path]::GetFullPath($env:SystemRoot)
        $powerShellPath = Join-Path $windowsDirectory "System32\WindowsPowerShell\v1.0\powershell.exe"
        $systemPath = [string]::Join(
            [IO.Path]::PathSeparator,
            @((Join-Path $windowsDirectory "System32"), $windowsDirectory))
        $environment = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        $environment["CODEX_HOME"] = $codexHome
        $environment["HOME"] = $userHome
        $environment["USERPROFILE"] = $userHome
        $environment["LOCALAPPDATA"] = $localAppData
        $environment["APPDATA"] = $roamingAppData
        $environment["TEMP"] = $processTemp
        $environment["TMP"] = $processTemp
        $environment["PATH"] = $systemPath
        $environment["SYSTEMROOT"] = $windowsDirectory
        $environment["WINDIR"] = $windowsDirectory
        $environment["COMSPEC"] = Join-Path $windowsDirectory "System32\cmd.exe"
        $environment["LANG"] = "C"
        $arguments = Get-ConfinementArguments `
            -Workspace $workspace `
            -CodexHome $codexHome `
            -UserHome $userHome `
            -Implementation $SandboxImplementation `
            -PowerShellPath $powerShellPath `
            -ProbePath $probePath `
            -ForeignRoot $foreignRoot `
            -Port $port
        $result = Invoke-BoundedProcess `
            -FilePath $codex `
            -Arguments $arguments `
            -Environment $environment `
            -TimeoutSeconds 45
        $listenerReached = $acceptTask.Wait(0)
        if ($listenerReached) {
            $acceptTask.Result.Dispose()
        }
        if ($result.ExitCode -ne 0) {
            if (
                $ExpectUnelevatedReadOnlyRejection -and
                (Test-ExpectedUnelevatedRejection -Stdout $result.Stdout -Stderr $result.Stderr)
            ) {
                $receipt = [ordered]@{
                    schemaVersion = 1
                    status = "passed"
                    codexVersion = $SupportedVersion
                    sandboxImplementation = $SandboxImplementation
                    mode = "negative-control"
                    checks = [ordered]@{
                        pinnedExecutable = $true
                        validAuthenticode = $true
                        readOnlyFallbackRejected = $true
                        elevatedRequired = $true
                        diagnosticBounded = $true
                    }
                }
                Write-Host "PASS unelevated Codex sandbox rejected the read-only generation profile"
                Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
                return
            }
            $sensitiveValues = @(
                $codex,
                $root,
                $workspace,
                $codexHome,
                $userHome,
                $foreignRoot,
                $probePath,
                $temporaryRoot,
                $env:USERPROFILE,
                $env:RUNNER_TEMP,
                $env:GITHUB_WORKSPACE
            )
            $stderrDiagnostic = Get-SanitizedDiagnostic -Text $result.Stderr -SensitiveValues $sensitiveValues
            $stdoutDiagnostic = Get-SanitizedDiagnostic -Text $result.Stdout -SensitiveValues $sensitiveValues
            Write-Warning "Codex sandbox stderr: $stderrDiagnostic"
            Write-Warning "Codex sandbox stdout: $stdoutDiagnostic"
            throw "Sandbox probe process failed."
        }
        if ($ExpectUnelevatedReadOnlyRejection) {
            throw "The unelevated sandbox unexpectedly accepted the read-only generation profile."
        }
        if ($result.Stderr.Length -gt $MaximumStderrCharacters) {
            throw "Sandbox probe stderr exceeded its limit."
        }
        foreach ($marker in @("allowed-canary", "codex-home-canary", "outside-root-canary")) {
            if ($result.Stderr.Contains($marker, [StringComparison]::Ordinal)) {
                throw "Sandbox probe stderr disclosed a canary value."
            }
        }
        [void](ConvertFrom-ProbeOutput -Output $result.Stdout)
        if ($listenerReached) {
            throw "Sandbox probe reached the loopback listener."
        }
        if (Test-Path -LiteralPath (Join-Path $workspace "write-attempt.txt")) {
            throw "Sandbox probe wrote inside its read-only workspace."
        }
        $receipt = [ordered]@{
            schemaVersion = 1
            status = "passed"
            codexVersion = $SupportedVersion
            sandboxImplementation = $SandboxImplementation
            checks = [ordered]@{
                pinnedExecutable = $true
                validAuthenticode = $true
                workspaceRead = $true
                workspaceWriteDenied = $true
                codexHomeReadDenied = $true
                userHomeReadDenied = $true
                outsideRootReadDenied = $true
                networkDenied = $true
                listenerUnreached = $true
                stderrBounded = $true
            }
        }
        Write-Host "PASS Codex generation confinement canary"
        Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
    }
    finally {
        if ($null -ne $listener) { $listener.Stop() }
        Remove-ValidatedTemporaryRoot -Path $foreignRoot -TemporaryRoot $temporaryRoot -ExpectedPrefix $ForeignPrefix
        Remove-ValidatedTemporaryRoot -Path $root -TemporaryRoot $temporaryRoot -ExpectedPrefix $RootPrefix
    }
}

try {
    if ($SelfTest) {
        Invoke-SelfTest
    }
    else {
        Invoke-Canary
    }
}
catch {
    Write-Error "FAIL Codex generation confinement canary: $($_.Exception.Message)"
    exit 1
}
