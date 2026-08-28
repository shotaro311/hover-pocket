[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$MsiPath,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedProductVersion,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedUpgradeCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Release-ComObject {
  param([AllowNull()][object]$Value)

  if ($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value)
  }
}

function Invoke-MsiQuery {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Database,

    [Parameter(Mandatory = $true)]
    [string]$Sql,

    [Parameter(Mandatory = $true)]
    [string[]]$Columns
  )

  $view = $null
  $record = $null
  $rows = [Collections.Generic.List[object]]::new()
  try {
    $view = $Database.OpenView($Sql)
    $view.Execute()
    while ($null -ne ($record = $view.Fetch())) {
      $row = [ordered]@{}
      for ($index = 0; $index -lt $Columns.Count; $index++) {
        $row[$Columns[$index]] = [string]$record.StringData($index + 1)
      }
      $rows.Add([pscustomobject]$row)
      Release-ComObject $record
      $record = $null
    }
  }
  finally {
    Release-ComObject $record
    if ($null -ne $view) {
      $view.Close()
    }
    Release-ComObject $view
  }

  return $rows.ToArray()
}

function Test-MsiTableExists {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Database,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$TableName
  )

  $rows = @(Invoke-MsiQuery `
    -Database $Database `
    -Sql "SELECT ``Name`` FROM ``_Tables`` WHERE ``Name``='$TableName'" `
    -Columns @("Name"))
  return $rows.Count -eq 1
}

function Test-MsiTableHasRows {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Database,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$TableName
  )

  if (-not (Test-MsiTableExists -Database $Database -TableName $TableName)) {
    return $false
  }

  $view = $null
  $record = $null
  try {
    $view = $Database.OpenView("SELECT * FROM ``$TableName``")
    $view.Execute()
    $record = $view.Fetch()
    return $null -ne $record
  }
  finally {
    Release-ComObject $record
    if ($null -ne $view) {
      $view.Close()
    }
    Release-ComObject $view
  }
}

function Assert-ExactSingleValue {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Rows,

    [Parameter(Mandatory = $true)]
    [string]$PropertyName,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedValue,

    [Parameter(Mandatory = $true)]
    [string]$FailureCode
  )

  if ($Rows.Count -ne 1 -or [string]$Rows[0].$PropertyName -cne $ExpectedValue) {
    throw $FailureCode
  }
}

function Get-MsiLongName {
  param([Parameter(Mandatory = $true)][string]$Value)

  $targetName = $Value.Split(":", 2)[0]
  $parts = $targetName.Split("|", 2)
  return $parts[$parts.Count - 1]
}

function Assert-DirectoryDescendsFrom {
  param(
    [Parameter(Mandatory = $true)]
    [Collections.Generic.Dictionary[string, string]]$Parents,

    [Parameter(Mandatory = $true)]
    [string]$DirectoryId,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedAncestor
  )

  $current = $DirectoryId
  $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  while ($visited.Add($current)) {
    if ($current -ceq $ExpectedAncestor) {
      return
    }
    if (-not $Parents.ContainsKey($current)) {
      break
    }
    $current = $Parents[$current]
  }
  throw "HP_CODEX_SANDBOX_MSI_COMPONENT_OUTSIDE_FIXED_ROOT"
}

$resolvedMsi = $null
$installer = $null
$database = $null
try {
  $resolvedMsi = Get-Item -LiteralPath $MsiPath -Force
  if (-not $resolvedMsi.PSIsContainer `
      -and ($resolvedMsi.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
    $resolvedMsiPath = $resolvedMsi.FullName
  }
  else {
    throw "HP_CODEX_SANDBOX_MSI_PATH_REJECTED"
  }

  $normalizedExpectedUpgradeCode = "{$($ExpectedUpgradeCode.Trim('{}').ToUpperInvariant())}"
  if ($normalizedExpectedUpgradeCode -notmatch '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$') {
    throw "HP_CODEX_SANDBOX_MSI_EXPECTED_UPGRADE_CODE_INVALID"
  }

  $installer = New-Object -ComObject WindowsInstaller.Installer
  $database = $installer.OpenDatabase($resolvedMsiPath, 0)

  $allUsers = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ALLUSERS'" `
    -Columns @("Value"))
  Assert-ExactSingleValue $allUsers "Value" "1" "HP_CODEX_SANDBOX_MSI_NOT_PER_MACHINE"

  $productVersion = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'" `
    -Columns @("Value"))
  Assert-ExactSingleValue `
    $productVersion `
    "Value" `
    $ExpectedProductVersion `
    "HP_CODEX_SANDBOX_MSI_VERSION_MISMATCH"

  $upgradeCode = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='UpgradeCode'" `
    -Columns @("Value"))
  Assert-ExactSingleValue `
    $upgradeCode `
    "Value" `
    $normalizedExpectedUpgradeCode `
    "HP_CODEX_SANDBOX_MSI_UPGRADE_CODE_MISMATCH"

  $directoryRows = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Directory``, ``Directory_Parent``, ``DefaultDir`` FROM ``Directory``" `
    -Columns @("Directory", "Parent", "DefaultDir"))
  $directories = @{}
  $parents = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
  foreach ($row in $directoryRows) {
    if ($directories.ContainsKey($row.Directory)) {
      throw "HP_CODEX_SANDBOX_MSI_DIRECTORY_DUPLICATE"
    }
    $directories[$row.Directory] = $row
    if (-not [string]::IsNullOrEmpty($row.Parent)) {
      $parents.Add($row.Directory, $row.Parent)
    }
  }
  foreach ($requiredDirectory in @("ProgramFiles64Folder", "HoverPocketProgramFilesFolder", "INSTALLFOLDER")) {
    if (-not $directories.ContainsKey($requiredDirectory)) {
      throw "HP_CODEX_SANDBOX_MSI_FIXED_ROOT_MISSING"
    }
  }
  if ($directories["HoverPocketProgramFilesFolder"].Parent -cne "ProgramFiles64Folder" `
      -or (Get-MsiLongName $directories["HoverPocketProgramFilesFolder"].DefaultDir) -cne "HoverPocket" `
      -or $directories["INSTALLFOLDER"].Parent -cne "HoverPocketProgramFilesFolder" `
      -or (Get-MsiLongName $directories["INSTALLFOLDER"].DefaultDir) -cne "CodexSandboxSetup") {
    throw "HP_CODEX_SANDBOX_MSI_FIXED_ROOT_MISMATCH"
  }

  $componentRows = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Component``, ``Directory_``, ``Attributes`` FROM ``Component``" `
    -Columns @("Component", "Directory", "Attributes"))
  if ($componentRows.Count -eq 0) {
    throw "HP_CODEX_SANDBOX_MSI_COMPONENTS_MISSING"
  }
  $componentById = @{}
  foreach ($component in $componentRows) {
    $componentById[$component.Component] = $component
    Assert-DirectoryDescendsFrom $parents $component.Directory "INSTALLFOLDER"
    $attributes = [Convert]::ToInt32($component.Attributes, 10)
    if (($attributes -band 256) -ne 256) {
      throw "HP_CODEX_SANDBOX_MSI_COMPONENT_NOT_64_BIT"
    }
  }

  $fileRows = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``File``, ``Component_``, ``FileName`` FROM ``File``" `
    -Columns @("File", "Component", "FileName"))
  if ($fileRows.Count -eq 0) {
    throw "HP_CODEX_SANDBOX_MSI_FILES_MISSING"
  }
  $helperMatches = @($fileRows | Where-Object {
    (Get-MsiLongName $_.FileName) -ceq "HoverPocket.CodexSandboxSetup.exe"
  })
  if ($helperMatches.Count -ne 1) {
    throw "HP_CODEX_SANDBOX_MSI_HELPER_NOT_EXACT"
  }
  foreach ($file in $fileRows) {
    if (-not $componentById.ContainsKey($file.Component)) {
      throw "HP_CODEX_SANDBOX_MSI_FILE_COMPONENT_MISSING"
    }
  }

  foreach ($forbiddenTable in @(
    "CustomAction",
    "ServiceInstall",
    "ServiceControl",
    "Registry",
    "Environment",
    "Shortcut")) {
    if (Test-MsiTableHasRows -Database $database -TableName $forbiddenTable) {
      throw "HP_CODEX_SANDBOX_MSI_FORBIDDEN_TABLE_$($forbiddenTable.ToUpperInvariant())"
    }
  }

  $mediaRows = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Cabinet`` FROM ``Media``" `
    -Columns @("Cabinet"))
  if ($mediaRows.Count -eq 0 `
      -or @($mediaRows | Where-Object { -not ($_.Cabinet.StartsWith("#", [StringComparison]::Ordinal)) }).Count -ne 0) {
    throw "HP_CODEX_SANDBOX_MSI_CABINET_NOT_EMBEDDED"
  }

  $sequenceRows = @(Invoke-MsiQuery `
    -Database $database `
    -Sql "SELECT ``Action``, ``Sequence`` FROM ``InstallExecuteSequence`` WHERE ``Action``='InstallInitialize' OR ``Action``='RemoveExistingProducts' OR ``Action``='InstallFinalize'" `
    -Columns @("Action", "Sequence"))
  $sequences = @{}
  foreach ($row in $sequenceRows) {
    if ($sequences.ContainsKey($row.Action)) {
      throw "HP_CODEX_SANDBOX_MSI_SEQUENCE_DUPLICATE"
    }
    $sequences[$row.Action] = [Convert]::ToInt32($row.Sequence, 10)
  }
  foreach ($action in @("InstallInitialize", "RemoveExistingProducts", "InstallFinalize")) {
    if (-not $sequences.ContainsKey($action)) {
      throw "HP_CODEX_SANDBOX_MSI_UPGRADE_SEQUENCE_MISSING"
    }
  }
  if ($sequences["RemoveExistingProducts"] -le $sequences["InstallInitialize"] `
      -or $sequences["RemoveExistingProducts"] -ge $sequences["InstallFinalize"]) {
    throw "HP_CODEX_SANDBOX_MSI_UPGRADE_NOT_TRANSACTIONAL"
  }

  Write-Output "PASS Codex sandbox per-machine installer contract"
}
finally {
  Release-ComObject $database
  Release-ComObject $installer
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
}
