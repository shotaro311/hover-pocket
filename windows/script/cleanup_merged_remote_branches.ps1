[CmdletBinding()]
param(
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

$branches = @(
    "codex/windows-0.2.2-release",
    "codex/windows-0.2.3-arp-fix",
    "codex/windows-unpublished-recovery-20260726",
    "feature/ai-native-phase1",
    "mac/panel-size-controls"
)

Write-Host "Repository: $repoRoot"
Write-Host "Mode      : $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })"

& git fetch origin --prune
if ($LASTEXITCODE -ne 0) {
    throw "git fetch origin --prune failed."
}

$candidates = [System.Collections.Generic.List[string]]::new()
foreach ($branch in $branches) {
    & git show-ref --verify --quiet "refs/remotes/origin/$branch"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "SKIP    $branch (already absent)"
        continue
    }

    $aheadText = (& git rev-list --count "origin/main..origin/$branch" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not compare origin/$branch with origin/main."
    }

    $behindText = (& git rev-list --count "origin/$branch..origin/main" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not compare origin/main with origin/$branch."
    }

    $ahead = [int]$aheadText
    $behind = [int]$behindText
    if ($ahead -ne 0) {
        throw "Refusing to delete $branch because it has $ahead commit(s) not in origin/main."
    }

    Write-Host "SAFE    $branch (ahead=$ahead, behind=$behind)"
    $candidates.Add($branch)
}

if ($candidates.Count -eq 0) {
    Write-Host "No stale remote branches remain." -ForegroundColor Green
    exit 0
}

if (-not $Execute) {
    Write-Host "`nDry run only. Re-run with -Execute to delete exactly the SAFE branches above." -ForegroundColor Yellow
    Write-Host ".\windows\script\cleanup_merged_remote_branches.ps1 -Execute"
    exit 0
}

foreach ($branch in $candidates) {
    Write-Host "Deleting origin/$branch ..." -ForegroundColor Cyan
    & git push origin --delete $branch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete origin/$branch. Remaining branches were not processed."
    }
}

& git fetch origin --prune
if ($LASTEXITCODE -ne 0) {
    throw "Final git fetch origin --prune failed."
}

Write-Host "`nPASS: stale remote branches were deleted after ahead=0 verification." -ForegroundColor Green
