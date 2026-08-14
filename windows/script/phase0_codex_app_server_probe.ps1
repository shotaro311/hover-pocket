[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 20,
    [string]$OutputDirectory = (Join-Path $env:TEMP ("HoverPocket-CodexPhase0-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [switch]$KeepRaw
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-ResponseStatus {
    param($Response)

    if ($null -eq $Response) {
        return "missing"
    }

    if ($null -ne $Response.PSObject.Properties["error"] -and $null -ne $Response.error) {
        return "error"
    }

    if ($null -ne $Response.PSObject.Properties["result"]) {
        return "ok"
    }

    return "unknown"
}

function Get-ArrayCountFromResult {
    param($Response)

    if ($null -eq $Response -or $null -eq $Response.PSObject.Properties["result"]) {
        return $null
    }

    $result = $Response.result
    if ($null -eq $result) {
        return 0
    }

    if ($result -is [System.Array]) {
        return $result.Count
    }

    foreach ($propertyName in @("voices", "data")) {
        $property = $result.PSObject.Properties[$propertyName]
        if ($null -eq $property) {
            continue
        }
        if ($property.Value -is [System.Array]) {
            return $property.Value.Count
        }
        if ($propertyName -eq "voices" -and $null -ne $property.Value) {
            $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($voiceGroup in @("v1", "v2", "available")) {
                $group = $property.Value.PSObject.Properties[$voiceGroup]
                if ($null -ne $group -and $group.Value -is [System.Array]) {
                    foreach ($voice in $group.Value) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$voice)) {
                            [void]$unique.Add([string]$voice)
                        }
                    }
                }
            }
            return $unique.Count
        }
    }

    return $null
}

Write-Step "Codex CLIを確認"
$codexCommand = Get-Command codex -ErrorAction Stop
$codexPath = $codexCommand.Source
$codexVersion = (& $codexPath --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "codex --version failed with exit code $LASTEXITCODE"
}

Write-Host "Codex: $codexVersion"
Write-Host "Path : $codexPath"

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$schemaDirectory = Join-Path $OutputDirectory "schema"
$stdoutPath = Join-Path $OutputDirectory "app-server.stdout.jsonl"
$stderrPath = Join-Path $OutputDirectory "app-server.stderr.log"
$summaryPath = Join-Path $OutputDirectory "summary.json"

Write-Step "インストール済みCodexからJSON Schemaを生成"
New-Item -ItemType Directory -Path $schemaDirectory -Force | Out-Null
$schemaOutput = & $codexPath app-server generate-json-schema --experimental --out $schemaDirectory 2>&1
$schemaExitCode = $LASTEXITCODE
$schemaGenerated = $schemaExitCode -eq 0
if (-not $schemaGenerated) {
    Write-Warning ("generate-json-schema failed: " + ($schemaOutput | Out-String).Trim())
}

$schemaRealtimeStartPresent = $false
$schemaRealtimeSdpPresent = $false
$schemaListVoicesPresent = $false
if ($schemaGenerated) {
    $clientRequestPath = Join-Path $schemaDirectory "ClientRequest.json"
    $serverNotificationPath = Join-Path $schemaDirectory "ServerNotification.json"
    if ((Test-Path $clientRequestPath) -and (Test-Path $serverNotificationPath)) {
        $clientRequestSchema = Get-Content -Path $clientRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $serverNotificationSchema = Get-Content -Path $serverNotificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $clientMethods = @(
            $clientRequestSchema.oneOf |
                ForEach-Object { $_.properties.method.enum } |
                Where-Object { $null -ne $_ }
        )
        $serverNotificationMethods = @(
            $serverNotificationSchema.oneOf |
                ForEach-Object { $_.properties.method.enum } |
                Where-Object { $null -ne $_ }
        )
        $schemaRealtimeStartPresent = $clientMethods -contains "thread/realtime/start"
        $schemaListVoicesPresent = $clientMethods -contains "thread/realtime/listVoices"
        $schemaRealtimeSdpPresent = $serverNotificationMethods -contains "thread/realtime/sdp"
    }
}

Write-Step "stdio JSONL handshakeとread-only endpointを確認"
$messages = @(
    [ordered]@{
        method = "initialize"
        id = 1
        params = [ordered]@{
            clientInfo = [ordered]@{
                name = "hover_pocket"
                title = "HoverPocket Phase 0 Probe"
                version = "0.0.0"
            }
            capabilities = [ordered]@{
                experimentalApi = $true
            }
        }
    },
    [ordered]@{
        method = "initialized"
        params = [ordered]@{}
    },
    [ordered]@{
        method = "account/read"
        id = 2
        params = [ordered]@{ refreshToken = $false }
    },
    [ordered]@{
        method = "account/rateLimits/read"
        id = 3
        params = [ordered]@{}
    },
    [ordered]@{
        method = "thread/realtime/listVoices"
        id = 4
        params = [ordered]@{}
    }
)

$responses = @{}
$notifications = 0
$nonJsonLines = 0
$outputLines = [System.Collections.Generic.List[string]]::new()
$timedOut = $false
$appServerExitCode = $null
$stderrText = ""
$process = $null
$processStarted = $false
try {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $extension = [System.IO.Path]::GetExtension($codexPath)
    if ($extension -in @(".cmd", ".bat")) {
        $startInfo.FileName = Join-Path ([Environment]::SystemDirectory) "cmd.exe"
        $startInfo.Arguments = '/d /s /c ""{0}" app-server --stdio"' -f $codexPath
    }
    elseif ($extension -eq ".ps1") {
        $powerShellPath = (Get-Process -Id $PID).Path
        $startInfo.FileName = $powerShellPath
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$codexPath`" app-server --stdio"
    }
    else {
        $startInfo.FileName = $codexPath
        $startInfo.Arguments = "app-server --stdio"
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.EnvironmentVariables["LOG_FORMAT"] = "json"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "codex app-server did not start"
    }
    $processStarted = $true
    $process.StandardInput.AutoFlush = $true
    $stderrTask = $process.StandardError.ReadToEndAsync()
    foreach ($request in $messages) {
        $process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 20 -Compress))
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($responses.Count -lt 4) {
        $remaining = $deadline - [DateTimeOffset]::UtcNow
        if ($remaining -le [TimeSpan]::Zero) {
            $timedOut = $true
            break
        }

        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait([Math]::Max(1, [int]$remaining.TotalMilliseconds))) {
            $timedOut = $true
            break
        }
        $line = $readTask.Result
        if ($null -eq $line) {
            break
        }
        $outputLines.Add($line)
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $message = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $nonJsonLines++
            continue
        }
        $idProperty = $message.PSObject.Properties["id"]
        if ($null -ne $idProperty -and $null -ne $idProperty.Value) {
            $responses[[string]$idProperty.Value] = $message
        }
        elseif ($null -ne $message.PSObject.Properties["method"]) {
            $notifications++
        }
    }

    $process.StandardInput.Close()
    if (-not $process.WaitForExit(3000)) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $appServerExitCode = $process.ExitCode
    $stderrText = $stderrTask.GetAwaiter().GetResult()
}
finally {
    if ($null -ne $process) {
        if ($processStarted -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

if ($timedOut) {
    Write-Warning "app-server probe timed out after $TimeoutSeconds seconds. The process was stopped."
}

if ($KeepRaw) {
    [System.IO.File]::WriteAllLines(
        $stdoutPath,
        [string[]]$outputLines,
        [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText(
        $stderrPath,
        $stderrText,
        [System.Text.UTF8Encoding]::new($false))
}

$initializeResponse = $responses["1"]
$accountResponse = $responses["2"]
$rateLimitsResponse = $responses["3"]
$voicesResponse = $responses["4"]
$stderrLineCount = @($stderrText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

$summary = [ordered]@{
    checkedAt = (Get-Date).ToString("o")
    codexVersion = $codexVersion
    codexPath = $codexPath
    schemaGenerated = $schemaGenerated
    schemaExitCode = $schemaExitCode
    schemaExperimental = $true
    schemaRealtimeStartPresent = $schemaRealtimeStartPresent
    schemaRealtimeSdpPresent = $schemaRealtimeSdpPresent
    schemaListVoicesPresent = $schemaListVoicesPresent
    appServerTimedOut = $timedOut
    appServerExitCode = $appServerExitCode
    initializeStatus = Get-ResponseStatus $initializeResponse
    accountReadStatus = Get-ResponseStatus $accountResponse
    rateLimitsReadStatus = Get-ResponseStatus $rateLimitsResponse
    listVoicesStatus = Get-ResponseStatus $voicesResponse
    voiceCount = Get-ArrayCountFromResult $voicesResponse
    notificationCount = $notifications
    nonJsonStdoutLineCount = $nonJsonLines
    stderrLineCount = $stderrLineCount
    reportDirectory = $OutputDirectory
    rawFilesRetained = [bool]$KeepRaw
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8

if (-not $KeepRaw) {
    Remove-Item -Path $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
}

Write-Step "安全な要約"
$summary | ConvertTo-Json -Depth 10
Write-Host "`nSummary: $summaryPath"
Write-Host "Schema : $schemaDirectory"

if (-not $schemaGenerated
    -or -not $schemaRealtimeStartPresent
    -or -not $schemaRealtimeSdpPresent
    -or -not $schemaListVoicesPresent
    -or $timedOut
    -or (Get-ResponseStatus $initializeResponse) -ne "ok"
    -or (Get-ResponseStatus $accountResponse) -ne "ok"
    -or (Get-ResponseStatus $rateLimitsResponse) -ne "ok"
    -or (Get-ResponseStatus $voicesResponse) -ne "ok") {
    Write-Warning "Phase 0 gate did not pass. Rerun with -KeepRaw only when debugging locally. Do not share raw account output."
    exit 2
}

exit 0
