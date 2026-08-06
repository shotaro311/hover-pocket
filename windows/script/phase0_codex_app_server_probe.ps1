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
        if ($null -ne $property -and $property.Value -is [System.Array]) {
            return $property.Value.Count
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
$schemaOutput = & $codexPath app-server generate-json-schema --out $schemaDirectory 2>&1
$schemaExitCode = $LASTEXITCODE
$schemaGenerated = $schemaExitCode -eq 0
if (-not $schemaGenerated) {
    Write-Warning ("generate-json-schema failed: " + ($schemaOutput | Out-String).Trim())
}

$schemaRealtimeStartPresent = $false
$schemaRealtimeSdpPresent = $false
$schemaListVoicesPresent = $false
if ($schemaGenerated) {
    $schemaFiles = Get-ChildItem -Path $schemaDirectory -Recurse -File
    $schemaRealtimeStartPresent = $null -ne ($schemaFiles | Select-String -Pattern 'thread/realtime/start' -SimpleMatch | Select-Object -First 1)
    $schemaRealtimeSdpPresent = $null -ne ($schemaFiles | Select-String -Pattern 'thread/realtime/sdp' -SimpleMatch | Select-Object -First 1)
    $schemaListVoicesPresent = $null -ne ($schemaFiles | Select-String -Pattern 'thread/realtime/listVoices' -SimpleMatch | Select-Object -First 1)
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
    },
    [ordered]@{
        method = "account/rateLimits/read"
        id = 3
    },
    [ordered]@{
        method = "thread/realtime/listVoices"
        id = 4
    }
)

$payload = (($messages | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }) -join "`n") + "`n"

$job = Start-Job -ArgumentList $payload, $codexPath, $stdoutPath, $stderrPath -ScriptBlock {
    param($Payload, $CodexPath, $StdoutPath, $StderrPath)

    $outputLines = @($Payload | & $CodexPath app-server --stdio 2> $StderrPath)
    $exitCode = $LASTEXITCODE
    [System.IO.File]::WriteAllLines(
        $StdoutPath,
        [string[]]$outputLines,
        [System.Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        ExitCode = $exitCode
        OutputLineCount = $outputLines.Count
    }
}

$completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
$timedOut = $null -eq $completed
$jobResult = $null
if ($timedOut) {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Write-Warning "app-server probe timed out after $TimeoutSeconds seconds. The job was stopped."
}
else {
    $jobResult = Receive-Job -Job $job
}
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

$responses = @{}
$notifications = 0
$nonJsonLines = 0
if (Test-Path $stdoutPath) {
    foreach ($line in Get-Content -Path $stdoutPath -Encoding UTF8) {
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
}

$initializeResponse = $responses["1"]
$accountResponse = $responses["2"]
$rateLimitsResponse = $responses["3"]
$voicesResponse = $responses["4"]
$stderrLineCount = if (Test-Path $stderrPath) { @(Get-Content -Path $stderrPath).Count } else { 0 }

$summary = [ordered]@{
    checkedAt = (Get-Date).ToString("o")
    codexVersion = $codexVersion
    codexPath = $codexPath
    schemaGenerated = $schemaGenerated
    schemaExitCode = $schemaExitCode
    schemaRealtimeStartPresent = $schemaRealtimeStartPresent
    schemaRealtimeSdpPresent = $schemaRealtimeSdpPresent
    schemaListVoicesPresent = $schemaListVoicesPresent
    appServerTimedOut = $timedOut
    appServerExitCode = if ($null -ne $jobResult) { $jobResult.ExitCode } else { $null }
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

if ((Get-ResponseStatus $initializeResponse) -ne "ok") {
    Write-Warning "initialize did not succeed. Open summary.json and rerun with -KeepRaw only when debugging locally. Do not share raw account output."
    exit 2
}

exit 0
