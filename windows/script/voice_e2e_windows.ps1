[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Build", "Run", "Readback", "Stop")]
    [string]$Action,

    [string]$Root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$solution = Join-Path $repoRoot "windows\HoverPocket.Windows.sln"
$project = Join-Path $repoRoot "windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj"
$targetFramework = "net10.0-windows10.0.22621.0"
$executable = Join-Path $repoRoot "windows\src\HoverPocket.Shell\bin\Debug\$targetFramework\HoverPocket.Shell.exe"
$rootPrefix = "HoverPocketVoiceE2E-"
$receiptName = "voice-e2e-receipt.json"
$stopEventName = "Local\HoverPocket.Windows.VoiceE2E.Stop"

function Invoke-Build {
    dotnet restore $solution
    if ($LASTEXITCODE -ne 0) {
        throw "Windows solution restore failed."
    }

    dotnet build $solution -c Debug --no-restore -p:TreatWarningsAsErrors=true
    if ($LASTEXITCODE -ne 0) {
        throw "Debug Voice E2E build failed."
    }

    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Debug Voice E2E executable was not produced."
    }

    Write-Output "voice_e2e_executable=$executable"
}

function Resolve-IsolatedRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Candidate
    )

    if (-not (Test-Path -LiteralPath $Candidate -PathType Container)) {
        throw "The isolated Voice E2E root does not exist."
    }

    $resolved = (Resolve-Path -LiteralPath $Candidate).Path.TrimEnd('\')
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $allowedPrefix = $temporary + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The Voice E2E root must stay under the system temp directory."
    }

    if (-not [IO.Path]::GetFileName($resolved).StartsWith($rootPrefix, [StringComparison]::Ordinal)) {
        throw "The Voice E2E root name is invalid."
    }

    $rootItem = Get-Item -LiteralPath $resolved -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The Voice E2E root cannot be a reparse point."
    }

    return $resolved
}

function Import-SanitizedReceipt {
    param(
        [Parameter(Mandatory)]
        [string]$IsolatedRoot
    )

    $receiptPath = Join-Path $IsolatedRoot $receiptName
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "The sanitized Voice E2E receipt does not exist yet."
    }

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $allowed = @(
        "schemaVersion",
        "availability",
        "featureEnabled",
        "sessionStatus",
        "sessionCount",
        "rootThreadPresent",
        "transportAttached",
        "appServerProcessPresent",
        "microphoneAcquired",
        "microphoneCurrent",
        "remoteAudioTrackReceived",
        "remoteAudioTrackCurrent",
        "remoteAudioTrackEver",
        "remoteAudioPlaybackReceived",
        "remoteAudioPlaybackCurrent",
        "remoteAudioPlaybackEver",
        "userTranscriptCount",
        "assistantTranscriptCount",
        "completeTranscriptCount",
        "lastTransportEvent"
    )
    $actual = @($receipt.PSObject.Properties.Name)
    $unexpected = @($actual | Where-Object { $_ -notin $allowed })
    $missing = @($allowed | Where-Object { $_ -notin $actual })
    if ($unexpected.Count -gt 0 -or $missing.Count -gt 0) {
        throw "The Voice E2E receipt did not match the sanitized allowlist."
    }

    return $receipt | Select-Object $allowed
}

function Read-SanitizedReceipt {
    param(
        [Parameter(Mandatory)]
        [string]$IsolatedRoot
    )

    $receipt = Import-SanitizedReceipt -IsolatedRoot $IsolatedRoot
    Write-Output "voice_e2e_receipt=$(Join-Path $IsolatedRoot $receiptName)"
    $receipt
}

function Get-IsolatedVoiceE2EProcess {
    param(
        [Parameter(Mandatory)]
        [string]$IsolatedRoot
    )

    $expectedExecutable = [IO.Path]::GetFullPath($executable)
    $escapedRoot = [Regex]::Escape($IsolatedRoot)
    $voiceFlagPattern = '(?i)(?:^|\s)--voice-e2e(?=\s|$)'
    $rootArgumentPattern = '(?i)(?:^|\s)--voice-e2e-root\s+(?:"' + $escapedRoot + '"|' + $escapedRoot + ')(?=\s|$)'
    return @(Get-CimInstance Win32_Process -Filter "Name = 'HoverPocket.Shell.exe'" | Where-Object {
        $_.ExecutablePath -and
        [IO.Path]::GetFullPath($_.ExecutablePath).Equals($expectedExecutable, [StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -and
        $_.CommandLine -match $voiceFlagPattern -and
        $_.CommandLine -match $rootArgumentPattern
    })
}

switch ($Action) {
    "Build" {
        if ($Root) {
            throw "Build does not accept -Root."
        }
        Invoke-Build
    }
    "Run" {
        if ($Root) {
            throw "Run always creates a fresh root; do not pass -Root."
        }

        Invoke-Build
        $freshRoot = Join-Path ([IO.Path]::GetTempPath()) ($rootPrefix + [Guid]::NewGuid().ToString("N"))
        $createdRoot = (New-Item -ItemType Directory -Path $freshRoot).FullName
        if (@(Get-ChildItem -LiteralPath $createdRoot -Force).Count -ne 0) {
            throw "The fresh Voice E2E root was unexpectedly non-empty."
        }

        $quotedRoot = '"' + $createdRoot + '"'
        $process = Start-Process -FilePath $executable -ArgumentList @(
            "--voice-e2e",
            "--voice-e2e-root",
            $quotedRoot
        ) -PassThru
        Start-Sleep -Milliseconds 750
        if ($process.HasExited) {
            throw "The isolated Voice E2E process exited during startup."
        }

        Write-Output "voice_e2e_root=$createdRoot"
        Write-Output "voice_e2e_executable=$executable"
        Write-Output "voice_e2e_receipt=$(Join-Path $createdRoot $receiptName)"
        Write-Output "voice_e2e_next=Use an explicit in-app Voice button click before Windows microphone permission."
    }
    "Readback" {
        if (-not $Root) {
            throw "Readback requires -Root from the Run output."
        }
        $isolatedRoot = Resolve-IsolatedRoot -Candidate $Root
        Read-SanitizedReceipt -IsolatedRoot $isolatedRoot
    }
    "Stop" {
        if (-not $Root) {
            throw "Stop requires -Root from the Run output."
        }
        $isolatedRoot = Resolve-IsolatedRoot -Candidate $Root
        $matches = @(Get-IsolatedVoiceE2EProcess -IsolatedRoot $isolatedRoot)
        if ($matches.Count -gt 0) {
            $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting($stopEventName)
            try {
                [void]$stopEvent.Set()
            }
            finally {
                $stopEvent.Dispose()
            }

            foreach ($match in $matches) {
                Wait-Process -Id $match.ProcessId -Timeout 15 -ErrorAction SilentlyContinue
            }
        }

        $remaining = @(Get-IsolatedVoiceE2EProcess -IsolatedRoot $isolatedRoot)
        if ($remaining.Count -gt 0) {
            throw "The isolated Voice E2E process did not complete safe shutdown."
        }

        $receipt = Import-SanitizedReceipt -IsolatedRoot $isolatedRoot
        if ($receipt.transportAttached -or
            $receipt.appServerProcessPresent -or
            $receipt.microphoneCurrent -or
            $receipt.remoteAudioTrackCurrent -or
            $receipt.remoteAudioPlaybackCurrent) {
            throw "The sanitized receipt did not confirm safe shutdown."
        }

        Write-Output "voice_e2e_stopped=$($matches.Count)"
        Write-Output "voice_e2e_root_preserved=$isolatedRoot"
    }
}
