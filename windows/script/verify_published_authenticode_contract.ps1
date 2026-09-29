[CmdletBinding()]
param(
    [string]$TargetScript = (Join-Path $PSScriptRoot "verify_published_authenticode.ps1")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$resolvedTarget = (Resolve-Path -LiteralPath $TargetScript).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedTarget,
    [ref]$tokens,
    [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    $messages = $parseErrors | ForEach-Object { $_.Message }
    throw "Published Authenticode verifier has PowerShell parse errors: $($messages -join '; ')"
}

function Find-AstNodes {
    param([scriptblock]$Predicate)

    return @($ast.FindAll($Predicate, $true))
}

function Assert-ExactlyOneNode {
    param(
        [object[]]$Nodes,
        [string]$FailureCode
    )

    if ($Nodes.Count -ne 1) {
        throw $FailureCode
    }
    return $Nodes[0]
}

function Assert-NodeInsideBlock {
    param(
        $Node,
        [System.Management.Automation.Language.StatementBlockAst]$Block,
        [string]$FailureCode
    )

    if ($Node.Extent.StartOffset -lt $Block.Extent.StartOffset -or
        $Node.Extent.EndOffset -gt $Block.Extent.EndOffset) {
        throw $FailureCode
    }
}

$formalGuards = Find-AstNodes {
    param($node)
    if ($node -isnot [System.Management.Automation.Language.IfStatementAst] -or
        $node.Clauses.Count -ne 1 -or
        $null -ne $node.ElseClause) {
        return $false
    }
    $condition = ($node.Clauses[0].Item1.Extent.Text -replace '\s+', ' ').Trim()
    return $condition -ceq '$null -ne $codexSandboxContract -and -not $IdentityOnly'
}
$formalGuard = Assert-ExactlyOneNode -Nodes $formalGuards -FailureCode "HP_CODEX_SANDBOX_IDENTITY_GUARD_NOT_EXACT"
$formalBlock = $formalGuard.Clauses[0].Item2

$installerPathAssignments = Find-AstNodes {
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        ($node.Left.Extent.Text -replace '\s+', '') -ceq '$installerVerifierPath' -and
        $node.Right.Extent.Text -match 'verify_codex_sandbox_installer\.ps1'
}
$installerPathAssignment = Assert-ExactlyOneNode `
    -Nodes $installerPathAssignments `
    -FailureCode "HP_CODEX_SANDBOX_INSTALLER_VERIFIER_PATH_NOT_EXACT"
Assert-NodeInsideBlock `
    -Node $installerPathAssignment `
    -Block $formalBlock `
    -FailureCode "HP_CODEX_SANDBOX_INSTALLER_VERIFIER_PATH_OUTSIDE_FORMAL_GUARD"

$installerVerifierCalls = Find-AstNodes {
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '^\s*&\s*\$installerVerifierPath\b'
}
$installerVerifierCall = Assert-ExactlyOneNode `
    -Nodes $installerVerifierCalls `
    -FailureCode "HP_CODEX_SANDBOX_INSTALLER_VERIFIER_CALL_NOT_EXACT"
Assert-NodeInsideBlock `
    -Node $installerVerifierCall `
    -Block $formalBlock `
    -FailureCode "HP_CODEX_SANDBOX_INSTALLER_VERIFIER_OUTSIDE_FORMAL_GUARD"

$administrativeImageCalls = Find-AstNodes {
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq "Expand-CodexSandboxMsiAdministrativeImage"
}
$administrativeImageCall = Assert-ExactlyOneNode `
    -Nodes $administrativeImageCalls `
    -FailureCode "HP_CODEX_SANDBOX_ADMIN_IMAGE_CALL_NOT_EXACT"
Assert-NodeInsideBlock `
    -Node $administrativeImageCall `
    -Block $formalBlock `
    -FailureCode "HP_CODEX_SANDBOX_ADMIN_IMAGE_OUTSIDE_FORMAL_GUARD"

$administrativeImageFunctions = Find-AstNodes {
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Expand-CodexSandboxMsiAdministrativeImage"
}
$administrativeImageFunction = Assert-ExactlyOneNode `
    -Nodes $administrativeImageFunctions `
    -FailureCode "HP_CODEX_SANDBOX_ADMIN_IMAGE_FUNCTION_NOT_EXACT"
$msiexecCalls = @($administrativeImageFunction.Body.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq "Start-Process" -and
                $node.Extent.Text -match '(?i)msiexec\.exe'
        }, $true))
[void](Assert-ExactlyOneNode `
        -Nodes $msiexecCalls `
        -FailureCode "HP_CODEX_SANDBOX_MSIEXEC_CALL_NOT_EXACT")

$msiSignatureCalls = Find-AstNodes {
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq "Assert-TimestampedAuthenticode" -and
        $node.Extent.Text -match '\$codexSandboxMsiPath\b'
}
$msiSignatureCall = Assert-ExactlyOneNode `
    -Nodes $msiSignatureCalls `
    -FailureCode "HP_CODEX_SANDBOX_MSI_SIGNATURE_CALL_NOT_EXACT"
Assert-NodeInsideBlock `
    -Node $msiSignatureCall `
    -Block $formalBlock `
    -FailureCode "HP_CODEX_SANDBOX_MSI_SIGNATURE_OUTSIDE_FORMAL_GUARD"

$publisherPinChecks = Find-AstNodes {
    param($node)
    $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $node.Extent.Text -match '\$codexSandboxMsiSignerCertificateSha256\s+-cne\s+\$canonicalSignerCertificateSha256'
}
$publisherPinCheck = Assert-ExactlyOneNode `
    -Nodes $publisherPinChecks `
    -FailureCode "HP_CODEX_SANDBOX_MSI_PUBLISHER_PIN_NOT_EXACT"
Assert-NodeInsideBlock `
    -Node $publisherPinCheck `
    -Block $formalBlock `
    -FailureCode "HP_CODEX_SANDBOX_MSI_PUBLISHER_PIN_OUTSIDE_FORMAL_GUARD"

$orderedOffsets = @(
    $msiSignatureCall.Extent.StartOffset,
    $publisherPinCheck.Extent.StartOffset,
    $installerVerifierCall.Extent.StartOffset,
    $administrativeImageCall.Extent.StartOffset)
for ($index = 1; $index -lt $orderedOffsets.Count; $index++) {
    if ($orderedOffsets[$index - 1] -ge $orderedOffsets[$index]) {
        throw "HP_CODEX_SANDBOX_FORMAL_VERIFICATION_ORDER_INVALID"
    }
}

Write-Output "published_authenticode_identity_boundary_contract_verify=ok"
