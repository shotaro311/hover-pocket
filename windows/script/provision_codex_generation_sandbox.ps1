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

$SecureProvisioningAvailable = $false

function Invoke-SelfTest {
    if ($SecureProvisioningAvailable) {
        throw "SELF_TEST_UNSAFE_PROVISIONING_ENABLED"
    }
    Write-Host "PASS Codex generation sandbox provisioning is fail-closed"
}

try {
    if ($SelfTest) {
        Invoke-SelfTest
        exit 0
    }

    # Keep parameter compatibility while refusing before path resolution, file access,
    # administrator checks, directory creation, binary copy, or process launch.
    [void]$CodexBin
    [void]$CodexHome
    [void]$Provision
    throw "HP_CODEX_SANDBOX_SETUP_UNAVAILABLE"
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^HP_CODEX_SANDBOX_[A-Z0-9_]+$') {
        $code = "HP_CODEX_SANDBOX_UNCLASSIFIED"
    }
    Write-Error "FAIL Codex generation sandbox provisioning: $code"
    exit 1
}
