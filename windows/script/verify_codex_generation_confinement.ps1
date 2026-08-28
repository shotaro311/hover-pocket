[CmdletBinding(DefaultParameterSetName = "Canary")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Canary")]
    [string]$CodexBin,

    [Parameter(ParameterSetName = "Canary")]
    [ValidateSet("elevated", "unelevated")]
    [string]$SandboxImplementation = "elevated",

    [Parameter(ParameterSetName = "Canary")]
    [switch]$ExpectUnelevatedReadOnlyRejection,

    [Parameter(ParameterSetName = "Canary")]
    [string]$ResultPath,

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
$HostCodexHomePrefix = "HoverPocketCodexHostHome-"
$CanaryBasePrefix = "HoverPocketCodexConfinementCanary-"
$ResultPrefix = "HoverPocketCodexConfinementResult-"
$SelfTestProfilePrefix = "HoverPocketCodexFrontierSelfTest-"
$MaximumStdoutCharacters = 16384
$MaximumStderrCharacters = 32768
$MaximumConfinementDenyEntries = 256
$MaximumConfinementDenyCharacters = 16384
$ProcessTimeoutSeconds = 90
$UnelevatedReadOnlyRejection = "windows sandbox failed: Restricted read-only access requires the elevated Windows sandbox backend"
$ExpectedProbe = [ordered]@{
    foreign_read = $false
    host_codex_home_read = $false
    network_connected = $false
    runtime_codex_home_read = $true
    user_home_read = $false
    workspace_read = $true
    workspace_write = $false
}
$script:CanaryFailureContext = $null

$ProbeScript = @'
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$RuntimeCodexHome,
    [Parameter(Mandatory = $true)][string]$HostCodexHome,
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
[Console]::Error.WriteLine("HP_PROBE_STAGE_STARTED")
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
[Console]::Error.WriteLine("HP_PROBE_STAGE_NETWORK_COMPLETE")

$foreignRead = Test-Readable (Join-Path $ForeignRoot "denied.txt")
[Console]::Error.WriteLine("HP_PROBE_STAGE_FOREIGN_READ_COMPLETE")
$hostCodexHomeRead = Test-Readable (Join-Path $HostCodexHome "denied.txt")
[Console]::Error.WriteLine("HP_PROBE_STAGE_HOST_CODEX_HOME_READ_COMPLETE")
$runtimeCodexHomeRead = Test-Readable (Join-Path $RuntimeCodexHome "runtime.txt")
[Console]::Error.WriteLine("HP_PROBE_STAGE_RUNTIME_CODEX_HOME_READ_COMPLETE")
$userHomeRead = Test-Readable (Join-Path $UserHome "denied.txt")
[Console]::Error.WriteLine("HP_PROBE_STAGE_USER_HOME_READ_COMPLETE")
$workspaceRead = Test-Readable (Join-Path $Workspace "allowed.txt")
[Console]::Error.WriteLine("HP_PROBE_STAGE_WORKSPACE_READ_COMPLETE")
$workspaceWrite = Test-Writable (Join-Path $Workspace "write-attempt.txt")
[Console]::Error.WriteLine("HP_PROBE_STAGE_WORKSPACE_WRITE_COMPLETE")

[ordered]@{
    foreign_read = $foreignRead
    host_codex_home_read = $hostCodexHomeRead
    network_connected = $networkConnected
    runtime_codex_home_read = $runtimeCodexHomeRead
    user_home_read = $userHomeRead
    workspace_read = $workspaceRead
    workspace_write = $workspaceWrite
} | ConvertTo-Json -Compress
'@

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.IndexOfAny([char[]](0..31)) -ge 0) {
        throw "A confinement value contains a control character."
    }
    return ($Value | ConvertTo-Json -Compress)
}

function Get-CanaryFailureCode {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($Message -cmatch '^HP_CANARY_[A-Z0-9_]+$') { return $Message }
    if ($Message -ceq "Confinement deny frontier exceeds the bounded permission profile.") {
        return "HP_CANARY_CONFINEMENT_FRONTIER_LIMIT"
    }
    if ($Message.StartsWith("Confinement deny frontier ", [StringComparison]::Ordinal)) {
        return "HP_CANARY_CONFINEMENT_FRONTIER_INVALID"
    }
    return "HP_CANARY_UNCLASSIFIED"
}

function Get-TrustedWindowsUserName {
    $userName = [Environment]::UserName
    if (
        [string]::IsNullOrWhiteSpace($userName) -or
        $userName.IndexOfAny([char[]](0..31)) -ge 0
    ) {
        throw "The Windows user name is unavailable for sandbox setup."
    }
    return $userName
}

function Get-ConfinementDenyFrontier {
    param(
        [Parameter(Mandatory = $true)][string]$HostUserProfile,
        [Parameter(Mandatory = $true)][string]$RunRoot
    )

    $hostUserProfilePath = [IO.Path]::GetFullPath($HostUserProfile).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $runRootPath = [IO.Path]::GetFullPath($RunRoot).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $hostUserProfileRoot = [IO.Path]::GetPathRoot($hostUserProfilePath).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $hostUserProfilePrefix = $hostUserProfilePath + [IO.Path]::DirectorySeparatorChar
    if (
        $hostUserProfilePath.StartsWith("\\", [StringComparison]::Ordinal) -or
        $hostUserProfilePath.Equals($hostUserProfileRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $runRootPath.StartsWith($hostUserProfilePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $hostUserProfilePath -PathType Container) -or
        -not (Test-Path -LiteralPath $runRootPath -PathType Container)
    ) {
        throw "Confinement deny frontier roots are invalid."
    }

    $frontier = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$frontier.Add($hostUserProfilePath)
    [void]$seen.Add($hostUserProfilePath)
    $characterCount = $hostUserProfilePath.Length
    $current = $hostUserProfilePath
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    while (-not $current.Equals($runRootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = [IO.Path]::GetRelativePath($current, $runRootPath)
        $components = @($relative.Split($separators, [StringSplitOptions]::RemoveEmptyEntries))
        if ($components.Count -eq 0) {
            throw "Confinement deny frontier could not resolve the run root."
        }
        $next = [IO.Path]::GetFullPath((Join-Path $current $components[0]))
        $currentPrefix = $current.TrimEnd($separators) + [IO.Path]::DirectorySeparatorChar
        $nextPrefix = $next.TrimEnd($separators) + [IO.Path]::DirectorySeparatorChar
        if (
            -not (Test-Path -LiteralPath $next -PathType Container) -or
            -not $next.StartsWith($currentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            (-not $next.Equals($runRootPath, [StringComparison]::OrdinalIgnoreCase) -and
                -not $runRootPath.StartsWith($nextPrefix, [StringComparison]::OrdinalIgnoreCase))
        ) {
            throw "Confinement deny frontier left the Host profile."
        }
        if (
            -not $next.Equals($runRootPath, [StringComparison]::OrdinalIgnoreCase) -and
            $seen.Add($next)
        ) {
            [void]$frontier.Add($next)
            $characterCount += $next.Length
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop | Sort-Object FullName)) {
            $sibling = [IO.Path]::GetFullPath($item.FullName)
            if (
                $sibling.Equals($next, [StringComparison]::OrdinalIgnoreCase) -or
                -not $seen.Add($sibling)
            ) {
                continue
            }
            [void]$frontier.Add($sibling)
            $characterCount += $sibling.Length
        }
        if (
            $frontier.Count -gt $MaximumConfinementDenyEntries -or
            $characterCount -gt $MaximumConfinementDenyCharacters
        ) {
            throw "Confinement deny frontier exceeds the bounded permission profile."
        }
        $current = $next
    }
    return $frontier.ToArray()
}

function Get-ConfinementArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$HostCodexHome,
        [Parameter(Mandatory = $true)][string]$UserHome,
        [Parameter(Mandatory = $true)][string]$HostUserProfile,
        [Parameter(Mandatory = $true)][string]$Implementation,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ProbePath,
        [Parameter(Mandatory = $true)][string]$ForeignRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $workspacePath = [IO.Path]::GetFullPath($Workspace)
    $codexHomePath = [IO.Path]::GetFullPath($CodexHome)
    $hostCodexHomePath = [IO.Path]::GetFullPath($HostCodexHome)
    $userHomePath = [IO.Path]::GetFullPath($UserHome)
    $hostUserProfilePath = [IO.Path]::GetFullPath($HostUserProfile).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $parentPaths = @(
        [IO.Path]::GetDirectoryName($workspacePath)
        [IO.Path]::GetDirectoryName($codexHomePath)
        [IO.Path]::GetDirectoryName($userHomePath)
    ) | Select-Object -Unique
    $rootPaths = @($workspacePath, $codexHomePath, $userHomePath) | Select-Object -Unique
    $runRootPath = [IO.Path]::GetDirectoryName($workspacePath).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $runRootPrefix = $runRootPath + [IO.Path]::DirectorySeparatorChar
    $hostUserProfilePrefix = $hostUserProfilePath + [IO.Path]::DirectorySeparatorChar
    $foreignRootPath = [IO.Path]::GetFullPath($ForeignRoot)
    $hostUserProfileRoot = [IO.Path]::GetPathRoot($hostUserProfilePath).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    if (
        @($parentPaths).Count -ne 1 -or
        @($rootPaths).Count -ne 3 -or
        $hostUserProfilePath.StartsWith("\\", [StringComparison]::Ordinal) -or
        $hostUserProfilePath.Equals($hostUserProfileRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $workspacePath.StartsWith($hostUserProfilePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $hostCodexHomePath.Equals($runRootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $hostCodexHomePath.StartsWith($runRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $hostCodexHomePath.StartsWith($hostUserProfilePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $foreignRootPath.Equals($runRootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $foreignRootPath.StartsWith($runRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $foreignRootPath.StartsWith($hostUserProfilePrefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Confinement roots must use a Host user-profile deny with an isolated workspace carveout."
    }

    $denyFrontier = @(Get-ConfinementDenyFrontier `
        -HostUserProfile $hostUserProfilePath `
        -RunRoot $runRootPath)
    $filesystemEntries = [Collections.Generic.List[string]]::new()
    [void]$filesystemEntries.Add("$(ConvertTo-TomlString ':minimal')=`"read`"")
    foreach ($denyPath in $denyFrontier) {
        [void]$filesystemEntries.Add("$(ConvertTo-TomlString $denyPath)=`"deny`"")
    }
    [void]$filesystemEntries.Add("$(ConvertTo-TomlString $workspacePath)=`"read`"")
    [void]$filesystemEntries.Add("$(ConvertTo-TomlString $userHomePath)=`"deny`"")
    $filesystem = "permissions.hoverpocket-generation.filesystem={" +
        [string]::Join(",", $filesystemEntries) + "}"
    $windowsDirectory = [IO.Path]::GetFullPath($env:SystemRoot)
    $systemDrive = [IO.Path]::GetPathRoot($windowsDirectory).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $systemPath = [string]::Join(
        [IO.Path]::PathSeparator,
        @((Join-Path $windowsDirectory "System32"), $windowsDirectory))
    $commandShell = Join-Path $windowsDirectory "System32\cmd.exe"
    $shellEnvironment = "shell_environment_policy.set={" +
        "PATH=$(ConvertTo-TomlString $systemPath)," +
        "LANG=`"C`"," +
        "SYSTEMDRIVE=$(ConvertTo-TomlString $systemDrive)," +
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
        "-RuntimeCodexHome", $codexHomePath
        "-HostCodexHome", $hostCodexHomePath
        "-UserHome", $userHomePath
        "-ForeignRoot", $foreignRootPath
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

function Resolve-ValidatedResultPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $fileName = [IO.Path]::GetFileName($fullPath)
    if (
        -not [IO.Path]::IsPathFullyQualified($fullPath) -or
        $fullPath.StartsWith("\\", [StringComparison]::Ordinal) -or
        -not $parent.Equals($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $fileName.StartsWith($ResultPrefix, [StringComparison]::Ordinal) -or
        -not $fileName.EndsWith(".json", [StringComparison]::Ordinal) -or
        ((Get-Item -LiteralPath $temporaryRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Test-Path -LiteralPath $fullPath)
    ) {
        throw "HP_CANARY_RESULT_PATH_INVALID"
    }
    return $fullPath
}

function Write-CanaryResult {
    param(
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Receipt
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath = Resolve-ValidatedResultPath -Path $Path
    $json = ($Receipt | ConvertTo-Json -Compress -Depth 5) + "`n"
    $encoding = [Text.UTF8Encoding]::new($false)
    $stream = [IO.FileStream]::new(
        $fullPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertFrom-ProbeOutput {
    param([Parameter(Mandatory = $true)][string]$Output)

    if ($Output.Length -gt $MaximumStdoutCharacters) {
        throw "HP_CANARY_PROBE_STDOUT_LIMIT"
    }
    $lines = @($Output -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -ne 1) {
        throw "HP_CANARY_PROBE_OUTPUT_SHAPE"
    }
    try {
        $payload = $lines[0] | ConvertFrom-Json
    }
    catch {
        throw "HP_CANARY_PROBE_OUTPUT_JSON"
    }
    $actualNames = @($payload.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @($ExpectedProbe.Keys | Sort-Object)
    if ([string]::Join("`n", $actualNames) -cne [string]::Join("`n", $expectedNames)) {
        throw "HP_CANARY_PROBE_OUTPUT_KEYS"
    }
    foreach ($entry in $ExpectedProbe.GetEnumerator()) {
        $value = $payload.PSObject.Properties[$entry.Key].Value
        if ($value -isnot [bool] -or $value -ne $entry.Value) {
            throw "HP_CANARY_PROBE_RESULT_$($entry.Key.ToUpperInvariant())"
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

    $script:CanaryFailureContext.stage = "process_binding_complete"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $script:CanaryFailureContext.stage = "process_argument_list"
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $script:CanaryFailureContext.stage = "process_environment"
    $start.Environment.Clear()
    foreach ($entry in $Environment.GetEnumerator()) {
        $start.Environment[$entry.Key] = $entry.Value
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        try {
            $script:CanaryFailureContext.stage = "process_start"
            $started = $process.Start()
        }
        catch {
            $argumentCharacters = 0
            $maximumArgumentCharacters = 0
            foreach ($argument in $Arguments) {
                $argumentCharacters += $argument.Length
                $maximumArgumentCharacters = [Math]::Max($maximumArgumentCharacters, $argument.Length)
            }
            $script:CanaryFailureContext = [ordered]@{
                processExitCode = $null
                stage = "process_start"
                exceptionType = $_.Exception.GetType().FullName
                argumentCount = $Arguments.Count
                argumentCharacters = $argumentCharacters
                maximumArgumentCharacters = $maximumArgumentCharacters
            }
            throw "HP_CANARY_PROCESS_START_EXCEPTION"
        }
        if (-not $started) {
            throw "HP_CANARY_PROCESS_START_FAILED"
        }
        $script:CanaryFailureContext.stage = "process_io"
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $script:CanaryFailureContext.stage = "process_wait"
        while (-not $process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 50
        }
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { }
            try { [void]$process.WaitForExit(5000) } catch { }
            $stdout = ""
            $stderr = ""
            try {
                if ($stdoutTask.Wait(2000)) {
                    $stdout = $stdoutTask.GetAwaiter().GetResult()
                }
            }
            catch { }
            try {
                if ($stderrTask.Wait(2000)) {
                    $stderr = $stderrTask.GetAwaiter().GetResult()
                }
            }
            catch { }
            return [pscustomobject]@{
                ExitCode = $null
                TimedOut = $true
                Stdout = $stdout
                Stderr = $stderr
            }
        }
        $script:CanaryFailureContext.stage = "process_readback"
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            TimedOut = $false
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
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$SensitiveValues
    )

    if ($null -eq $Text) {
        $Text = ""
    }
    $sanitized = $Text
    foreach ($value in $SensitiveValues) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $sanitized = $sanitized.Replace($value, "<path>", [StringComparison]::OrdinalIgnoreCase)
        }
    }
    foreach ($marker in @(
        "allowed-canary",
        "runtime-codex-home-canary",
        "host-codex-home-canary",
        "user-home-canary",
        "outside-root-canary",
        "write-canary")) {
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
    Assert-NoReparsePath -Path $TemporaryRoot
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (
        -not $parent.Equals([IO.Path]::GetFullPath($TemporaryRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($fullPath).StartsWith($ExpectedPrefix, [StringComparison]::Ordinal) -or
        ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "HP_CANARY_CLEANUP_VALIDATION_FAILED"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Invoke-SelfTest {
    try {
        [void](Get-SanitizedDiagnostic -Text ([string]$null) -SensitiveValues @("sensitive"))
    }
    catch {
        throw "Self-test null process diagnostic normalization failed."
    }
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
            $expectedFailure = "HP_CANARY_PROBE_RESULT_$($key.ToUpperInvariant())"
            if ($_.Exception.Message -cne $expectedFailure) {
                throw "Self-test observed an unexpected probe failure code."
            }
        }
    }
    if (
        -not (Test-ExpectedUnelevatedRejection -Stdout "" -Stderr ($UnelevatedReadOnlyRejection + "`r`n")) -or
        (Test-ExpectedUnelevatedRejection -Stdout "unexpected" -Stderr $UnelevatedReadOnlyRejection) -or
        (Test-ExpectedUnelevatedRejection -Stdout "" -Stderr "another failure")
    ) {
        throw "Self-test unelevated rejection contract failed."
    }
    if (
        (Get-CanaryFailureCode "HP_CANARY_PROCESS_FAILED") -cne "HP_CANARY_PROCESS_FAILED" -or
        (Get-CanaryFailureCode "Confinement deny frontier exceeds the bounded permission profile.") -cne
            "HP_CANARY_CONFINEMENT_FRONTIER_LIMIT" -or
        (Get-CanaryFailureCode "Confinement deny frontier roots are invalid.") -cne
            "HP_CANARY_CONFINEMENT_FRONTIER_INVALID" -or
        (Get-CanaryFailureCode "unexpected") -cne "HP_CANARY_UNCLASSIFIED"
    ) {
        throw "Self-test canary failure classification contract failed."
    }

    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $selfTestProfile = Join-Path $temporaryRoot ($SelfTestProfilePrefix + [Guid]::NewGuid().ToString("N"))
    $selfTestRunRoot = Join-Path $selfTestProfile "temp\run"
    $selfTestWorkspace = Join-Path $selfTestRunRoot "workspace"
    $selfTestCodexHome = Join-Path $selfTestRunRoot "codex-home"
    $selfTestUserHome = Join-Path $selfTestRunRoot "user-home"
    $selfTestHostCodexHome = Join-Path $selfTestProfile "temp\host-codex-home"
    $selfTestForeign = Join-Path $selfTestProfile "temp\foreign"
    $selfTestTemp = Join-Path $selfTestProfile "temp"
    $selfTestDocuments = Join-Path $selfTestProfile "Documents"
    foreach ($directory in @(
        $selfTestWorkspace,
        $selfTestCodexHome,
        $selfTestUserHome,
        $selfTestHostCodexHome,
        $selfTestForeign,
        $selfTestDocuments
    )) {
        [void](New-Item -ItemType Directory -Path $directory)
    }
    $oldSystemRoot = $env:SystemRoot
    try {
        $env:SystemRoot = "C:\Windows"
        $arguments = Get-ConfinementArguments `
            -Workspace $selfTestWorkspace `
            -CodexHome $selfTestCodexHome `
            -HostCodexHome $selfTestHostCodexHome `
            -UserHome $selfTestUserHome `
            -HostUserProfile $selfTestProfile `
            -Implementation "unelevated" `
            -PowerShellPath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ProbePath (Join-Path $selfTestWorkspace "probe.ps1") `
            -ForeignRoot $selfTestForeign `
            -Port 12345
        $joined = [string]::Join("`n", $arguments)
        $required = @(
            'windows.sandbox="unelevated"'
            'default_permissions="hoverpocket-generation"'
            "$(ConvertTo-TomlString $selfTestProfile)=`"deny`""
            "$(ConvertTo-TomlString $selfTestDocuments)=`"deny`""
            "$(ConvertTo-TomlString $selfTestTemp)=`"deny`""
            "$(ConvertTo-TomlString $selfTestHostCodexHome)=`"deny`""
            "$(ConvertTo-TomlString $selfTestForeign)=`"deny`""
            "$(ConvertTo-TomlString $selfTestWorkspace)=`"read`""
            "$(ConvertTo-TomlString $selfTestUserHome)=`"deny`""
            'network.enabled=false'
            'shell_environment_policy.inherit="none"'
            'SYSTEMDRIVE="C:"'
            'SYSTEMROOT="C:\\Windows"'
        )
        foreach ($marker in $required) {
            if (-not $joined.Contains($marker, [StringComparison]::Ordinal)) {
                throw "Self-test confinement arguments differ from the expected contract."
            }
        }
        if ($joined.Contains(
            "$(ConvertTo-TomlString $selfTestCodexHome)=`"deny`"",
            [StringComparison]::Ordinal)) {
            throw "Self-test must leave Codex Home to the native sandbox control-plane ACLs."
        }
        if ($joined.Contains(
            "$(ConvertTo-TomlString $selfTestRunRoot)=`"deny`"",
            [StringComparison]::Ordinal)) {
            throw "Self-test must preserve the isolated run-root carveout."
        }
        foreach ($index in 0..256) {
            [void](New-Item -ItemType Directory -Path (
                Join-Path $selfTestProfile ("overflow-{0:D3}" -f $index)))
        }
        try {
            [void](Get-ConfinementDenyFrontier `
                -HostUserProfile $selfTestProfile `
                -RunRoot $selfTestRunRoot)
            throw "Self-test accepted an unbounded confinement deny frontier."
        }
        catch {
            if ($_.Exception.Message -like "Self-test accepted*") { throw }
            if ($_.Exception.Message -cne "Confinement deny frontier exceeds the bounded permission profile.") {
                throw "Self-test observed an unexpected confinement frontier failure."
            }
        }
    }
    finally {
        $env:SystemRoot = $oldSystemRoot
        Remove-ValidatedTemporaryRoot `
            -Path $selfTestProfile `
            -TemporaryRoot $temporaryRoot `
            -ExpectedPrefix $SelfTestProfilePrefix
    }

    $selfTestResultPath = Join-Path (
        [IO.Path]::GetFullPath([IO.Path]::GetTempPath())) (
        $ResultPrefix + [Guid]::NewGuid().ToString("N") + ".json")
    try {
        $selfTestReceipt = [ordered]@{
            schemaVersion = 1
            status = "passed"
            mode = "self-test"
        }
        Write-CanaryResult -Path $selfTestResultPath -Receipt $selfTestReceipt
        $readback = Get-Content -LiteralPath $selfTestResultPath -Raw | ConvertFrom-Json
        if (
            $readback.schemaVersion -ne 1 -or
            $readback.status -cne "passed" -or
            $readback.mode -cne "self-test"
        ) {
            throw "Self-test result receipt readback failed."
        }
        try {
            Write-CanaryResult -Path $selfTestResultPath -Receipt $selfTestReceipt
            throw "Self-test overwrote an existing result receipt."
        }
        catch {
            if ($_.Exception.Message -like "Self-test overwrote*") { throw }
            if ($_.Exception.Message -cne "HP_CANARY_RESULT_PATH_INVALID") {
                throw "Self-test observed an unexpected result path failure code."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $selfTestResultPath) {
            Remove-Item -LiteralPath $selfTestResultPath -Force
        }
    }
    Write-Host "PASS Codex generation confinement verifier self-test"
}

function Invoke-Canary {
    if ($ExpectUnelevatedReadOnlyRejection -and $SandboxImplementation -cne "unelevated") {
        throw "The unelevated rejection expectation requires the unelevated implementation."
    }
    $script:CanaryFailureContext = [ordered]@{
        processExitCode = $null
        stage = "trusted_executable"
    }
    $codex = Resolve-TrustedCodexExecutable -Path $CodexBin
    $script:CanaryFailureContext = [ordered]@{
        processExitCode = $null
        stage = "root_validation"
    }
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $hostUserProfileValue = $env:USERPROFILE
    $localApplicationDataValue = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if (
        [string]::IsNullOrWhiteSpace($hostUserProfileValue) -or
        [string]::IsNullOrWhiteSpace($localApplicationDataValue)
    ) {
        throw "HP_CANARY_ROOT_INVALID"
    }
    $hostUserProfile = [IO.Path]::GetFullPath($hostUserProfileValue).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $localApplicationData = [IO.Path]::GetFullPath($localApplicationDataValue).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $hostUserProfilePrefix = $hostUserProfile + [IO.Path]::DirectorySeparatorChar
    if (
        $localApplicationData.StartsWith("\\", [StringComparison]::Ordinal) -or
        -not $localApplicationData.StartsWith($hostUserProfilePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $localApplicationData -PathType Container)
    ) {
        throw "HP_CANARY_ROOT_INVALID"
    }
    Assert-NoReparsePath -Path $localApplicationData
    $canaryBase = Join-Path $localApplicationData ($CanaryBasePrefix + [Guid]::NewGuid().ToString("N"))
    $root = Join-Path $canaryBase ($RootPrefix + [Guid]::NewGuid().ToString("N"))
    $foreignRoot = Join-Path $canaryBase ($ForeignPrefix + [Guid]::NewGuid().ToString("N"))
    $hostCodexHome = Join-Path $canaryBase ($HostCodexHomePrefix + [Guid]::NewGuid().ToString("N"))
    $listener = $null
    try {
        $script:CanaryFailureContext.stage = "base_creation"
        [void](New-Item -ItemType Directory -Path $canaryBase)
        Assert-NoReparsePath -Path $canaryBase
        $workspace = Join-Path $root "workspace"
        $codexHome = Join-Path $root "codex-home"
        $userHome = Join-Path $root "user-home"
        $localAppData = Join-Path $userHome "AppData\Local"
        $roamingAppData = Join-Path $userHome "AppData\Roaming"
        $processTemp = Join-Path $root "tmp"
        foreach ($directory in @($workspace, $codexHome, $hostCodexHome, $userHome, $localAppData, $roamingAppData, $processTemp, $foreignRoot)) {
            [void](New-Item -ItemType Directory -Path $directory)
        }
        [IO.File]::WriteAllText((Join-Path $workspace "allowed.txt"), "allowed-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $codexHome "runtime.txt"), "runtime-codex-home-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $hostCodexHome "denied.txt"), "host-codex-home-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $userHome "denied.txt"), "user-home-canary", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $foreignRoot "denied.txt"), "outside-root-canary", [Text.Encoding]::UTF8)
        $probePath = Join-Path $workspace "probe.ps1"
        [IO.File]::WriteAllText($probePath, $ProbeScript, [Text.UTF8Encoding]::new($false))

        $script:CanaryFailureContext.stage = "listener_creation"
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start(1)
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $acceptTask = $listener.AcceptTcpClientAsync()
        $windowsDirectory = [IO.Path]::GetFullPath($env:SystemRoot)
        $systemDrive = [IO.Path]::GetPathRoot($windowsDirectory).TrimEnd(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
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
        $environment["USERNAME"] = Get-TrustedWindowsUserName
        $environment["SYSTEMDRIVE"] = $systemDrive
        $environment["SYSTEMROOT"] = $windowsDirectory
        $environment["WINDIR"] = $windowsDirectory
        $environment["COMSPEC"] = Join-Path $windowsDirectory "System32\cmd.exe"
        $environment["LANG"] = "C"
        $script:CanaryFailureContext.stage = "argument_construction"
        $arguments = Get-ConfinementArguments `
            -Workspace $workspace `
            -CodexHome $codexHome `
            -HostCodexHome $hostCodexHome `
            -UserHome $userHome `
            -HostUserProfile $hostUserProfile `
            -Implementation $SandboxImplementation `
            -PowerShellPath $powerShellPath `
            -ProbePath $probePath `
            -ForeignRoot $foreignRoot `
            -Port $port
        [string[]]$processArguments = @($arguments | ForEach-Object { [string]$_ })
        $nullArgumentCount = @($processArguments | Where-Object { $null -eq $_ }).Count
        $emptyArgumentCount = @($processArguments | Where-Object { $_.Length -eq 0 }).Count
        $argumentCharacters = 0
        $maximumArgumentCharacters = 0
        foreach ($argument in $processArguments) {
            $argumentCharacters += $argument.Length
            $maximumArgumentCharacters = [Math]::Max($maximumArgumentCharacters, $argument.Length)
        }
        $filePathValues = @($codex)
        $filePathIsString = $codex -is [string]
        $filePathCharacters = if ($filePathIsString) { $codex.Length } else { 0 }
        $filePathFullyQualified = $filePathIsString -and [IO.Path]::IsPathFullyQualified($codex)
        $environmentNullKeyCount = @($environment.Keys | Where-Object { $null -eq $_ }).Count
        $environmentEmptyKeyCount = @($environment.Keys | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
        $environmentNullValueCount = @($environment.Values | Where-Object { $null -eq $_ }).Count
        $environmentEmptyValueCount = @($environment.Values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
        $script:CanaryFailureContext = [ordered]@{
            processExitCode = $null
            stage = "process_execution"
            filePathValueCount = $filePathValues.Count
            filePathIsString = $filePathIsString
            filePathCharacters = $filePathCharacters
            filePathFullyQualified = $filePathFullyQualified
            argumentCount = $processArguments.Count
            nullArgumentCount = $nullArgumentCount
            emptyArgumentCount = $emptyArgumentCount
            argumentCharacters = $argumentCharacters
            maximumArgumentCharacters = $maximumArgumentCharacters
            environmentCount = $environment.Count
            environmentNullKeyCount = $environmentNullKeyCount
            environmentEmptyKeyCount = $environmentEmptyKeyCount
            environmentNullValueCount = $environmentNullValueCount
            environmentEmptyValueCount = $environmentEmptyValueCount
            timeoutSeconds = $ProcessTimeoutSeconds
        }
        if (
            $filePathValues.Count -ne 1 -or
            -not $filePathIsString -or
            [string]::IsNullOrWhiteSpace($codex) -or
            -not $filePathFullyQualified -or
            $processArguments.Count -eq 0 -or
            $nullArgumentCount -ne 0 -or
            $emptyArgumentCount -ne 0 -or
            $environment.Count -eq 0 -or
            $environmentNullKeyCount -ne 0 -or
            $environmentEmptyKeyCount -ne 0 -or
            $environmentNullValueCount -ne 0 -or
            $environmentEmptyValueCount -ne 0 -or
            $ProcessTimeoutSeconds -le 0
        ) {
            throw "HP_CANARY_PROCESS_ARGUMENTS_INVALID"
        }
        $result = Invoke-BoundedProcess `
            -FilePath $codex `
            -Arguments $processArguments `
            -Environment $environment `
            -TimeoutSeconds $ProcessTimeoutSeconds
        $listenerReached = $acceptTask.Wait(0)
        if ($listenerReached) {
            $acceptTask.Result.Dispose()
        }
        if ($result.TimedOut) {
            $sensitiveValues = @(
                $codex,
                $root,
                $workspace,
                $codexHome,
                $hostCodexHome,
                $userHome,
                $foreignRoot,
                $probePath,
                $canaryBase,
                $localApplicationData,
                $temporaryRoot,
                $env:USERPROFILE,
                $env:RUNNER_TEMP,
                $env:GITHUB_WORKSPACE
            )
            $script:CanaryFailureContext.stage = "process_timeout"
            $script:CanaryFailureContext = [ordered]@{
                processExitCode = $null
                stage = "process_timeout"
                stderr = Get-SanitizedDiagnostic -Text ([string]$result.Stderr) -SensitiveValues $sensitiveValues
                stdout = Get-SanitizedDiagnostic -Text ([string]$result.Stdout) -SensitiveValues $sensitiveValues
            }
            throw "HP_CANARY_PROCESS_TIMEOUT"
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
                if ($null -ne $listener) {
                    $listener.Stop()
                    $listener = $null
                }
                Remove-ValidatedTemporaryRoot -Path $foreignRoot -TemporaryRoot $canaryBase -ExpectedPrefix $ForeignPrefix
                Remove-ValidatedTemporaryRoot -Path $hostCodexHome -TemporaryRoot $canaryBase -ExpectedPrefix $HostCodexHomePrefix
                Remove-ValidatedTemporaryRoot -Path $root -TemporaryRoot $canaryBase -ExpectedPrefix $RootPrefix
                Remove-ValidatedTemporaryRoot -Path $canaryBase -TemporaryRoot $localApplicationData -ExpectedPrefix $CanaryBasePrefix
                Write-CanaryResult -Path $ResultPath -Receipt $receipt
                Write-Host "PASS unelevated Codex sandbox rejected the read-only generation profile"
                Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
                return
            }
            $sensitiveValues = @(
                $codex,
                $root,
                $workspace,
                $codexHome,
                $hostCodexHome,
                $userHome,
                $foreignRoot,
                $probePath,
                $canaryBase,
                $localApplicationData,
                $temporaryRoot,
                $env:USERPROFILE,
                $env:RUNNER_TEMP,
                $env:GITHUB_WORKSPACE
            )
            $script:CanaryFailureContext = [ordered]@{
                processExitCode = $result.ExitCode
                stage = "process_failed"
            }
            $stderrDiagnostic = Get-SanitizedDiagnostic `
                -Text ([string]$result.Stderr) `
                -SensitiveValues $sensitiveValues
            $stdoutDiagnostic = Get-SanitizedDiagnostic `
                -Text ([string]$result.Stdout) `
                -SensitiveValues $sensitiveValues
            $script:CanaryFailureContext["stderr"] = [string]$stderrDiagnostic
            $script:CanaryFailureContext["stdout"] = [string]$stdoutDiagnostic
            Write-Warning "Codex sandbox stderr: $stderrDiagnostic"
            Write-Warning "Codex sandbox stdout: $stdoutDiagnostic"
            throw "HP_CANARY_PROCESS_FAILED"
        }
        if ($ExpectUnelevatedReadOnlyRejection) {
            throw "HP_CANARY_UNELEVATED_UNEXPECTED_SUCCESS"
        }
        if ($result.Stderr.Length -gt $MaximumStderrCharacters) {
            throw "HP_CANARY_PROBE_STDERR_LIMIT"
        }
        foreach ($marker in @(
            "allowed-canary",
            "runtime-codex-home-canary",
            "host-codex-home-canary",
            "user-home-canary",
            "outside-root-canary",
            "write-canary")) {
            if ($result.Stderr.Contains($marker, [StringComparison]::Ordinal)) {
                throw "HP_CANARY_STDERR_CANARY_DISCLOSURE"
            }
        }
        [void](ConvertFrom-ProbeOutput -Output $result.Stdout)
        if ($listenerReached) {
            throw "HP_CANARY_NETWORK_LISTENER_REACHED"
        }
        if (Test-Path -LiteralPath (Join-Path $workspace "write-attempt.txt")) {
            throw "HP_CANARY_WORKSPACE_WRITE_OBSERVED"
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
                isolatedCodexHomeReadable = $true
                hostCodexHomeReadDenied = $true
                userHomeReadDenied = $true
                outsideRootReadDenied = $true
                networkDenied = $true
                listenerUnreached = $true
                stderrBounded = $true
            }
        }
        if ($null -ne $listener) {
            $listener.Stop()
            $listener = $null
        }
        $script:CanaryFailureContext = [ordered]@{
            processExitCode = 0
            stage = "validated_cleanup"
        }
        Remove-ValidatedTemporaryRoot -Path $foreignRoot -TemporaryRoot $canaryBase -ExpectedPrefix $ForeignPrefix
        Remove-ValidatedTemporaryRoot -Path $hostCodexHome -TemporaryRoot $canaryBase -ExpectedPrefix $HostCodexHomePrefix
        Remove-ValidatedTemporaryRoot -Path $root -TemporaryRoot $canaryBase -ExpectedPrefix $RootPrefix
        Remove-ValidatedTemporaryRoot -Path $canaryBase -TemporaryRoot $localApplicationData -ExpectedPrefix $CanaryBasePrefix
        Write-CanaryResult -Path $ResultPath -Receipt $receipt
        Write-Host "PASS Codex generation confinement canary"
        Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
    }
    finally {
        if ($null -ne $listener) { $listener.Stop() }
        Remove-ValidatedTemporaryRoot -Path $foreignRoot -TemporaryRoot $canaryBase -ExpectedPrefix $ForeignPrefix
        Remove-ValidatedTemporaryRoot -Path $hostCodexHome -TemporaryRoot $canaryBase -ExpectedPrefix $HostCodexHomePrefix
        Remove-ValidatedTemporaryRoot -Path $root -TemporaryRoot $canaryBase -ExpectedPrefix $RootPrefix
        Remove-ValidatedTemporaryRoot -Path $canaryBase -TemporaryRoot $localApplicationData -ExpectedPrefix $CanaryBasePrefix
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
    $message = $_.Exception.Message
    $failureCode = Get-CanaryFailureCode -Message $message
    if ($failureCode -ceq "HP_CANARY_UNCLASSIFIED") {
        if ($null -eq $script:CanaryFailureContext) {
            $script:CanaryFailureContext = [ordered]@{
                processExitCode = $null
                stage = "unknown"
            }
        }
        if (-not $script:CanaryFailureContext.Contains("exceptionType")) {
            $script:CanaryFailureContext["exceptionType"] = $_.Exception.GetType().FullName
        }
        $errorId = [string]$_.FullyQualifiedErrorId
        if ($errorId -cmatch '^[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)?$') {
            $script:CanaryFailureContext["errorId"] = $errorId
        }
        $commandName = [string]$_.InvocationInfo.MyCommand.Name
        if ($commandName -cmatch '^[A-Za-z0-9_.-]+$') {
            $script:CanaryFailureContext["commandName"] = $commandName
        }
        $scriptLineNumber = [int]$_.InvocationInfo.ScriptLineNumber
        if ($scriptLineNumber -gt 0) {
            $script:CanaryFailureContext["scriptLineNumber"] = $scriptLineNumber
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $failureReceipt = [ordered]@{
            schemaVersion = 1
            status = "failed"
            failureCode = $failureCode
            diagnostic = $script:CanaryFailureContext
        }
        try {
            Write-CanaryResult -Path $ResultPath -Receipt $failureReceipt
        }
        catch {
            $failureCode = "HP_CANARY_RESULT_WRITE_FAILED"
        }
    }
    Write-Error "FAIL Codex generation confinement canary: $failureCode"
    exit 1
}
