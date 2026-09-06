param([Parameter(Mandatory)][string]$PublishDirectory, [Parameter(Mandatory)][string]$ReleaseDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$iconPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Resources\AppIcon.ico')).Path
$evidence = Join-Path (Split-Path (Split-Path $PublishDirectory)) '..\icon-verification'
$evidence = [IO.Path]::GetFullPath($evidence)
New-Item -ItemType Directory -Force $evidence | Out-Null
$expectedIcon = [Drawing.Icon]::new($iconPath, [Drawing.Size]::new(32,32))
$expected = $expectedIcon.ToBitmap()
$results = [ordered]@{}
try {
    $assembly = [Reflection.Assembly]::LoadFile((Join-Path $PublishDirectory 'HoverPocket.Shell.dll'))
    $stream = $assembly.GetManifestResourceStream('HoverPocket.AppIcon.ico')
    if (!$stream) { throw 'Tray icon resource is missing.' }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $resourceHash = [Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant() }
    finally { $stream.Dispose(); $hasher.Dispose() }
    if ($resourceHash -ne (Get-FileHash $iconPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Tray icon resource differs from approved ICO.' }
    $results.trayResourceSha256 = $resourceHash
    foreach ($entry in @(
        @{Name='application'; Path=(Join-Path $PublishDirectory 'HoverPocket.Shell.exe')},
        @{Name='installer'; Path=(Join-Path $ReleaseDirectory 'HoverPocketWin-win-Setup.exe')}
    )) {
        $icon = [Drawing.Icon]::ExtractAssociatedIcon($entry.Path)
        if (!$icon) { throw "No icon: $($entry.Name)" }
        $bitmap = $icon.ToBitmap()
        try {
            if ($bitmap.Size -ne $expected.Size) { throw "Unexpected icon size: $($entry.Name)" }
            $different = 0
            for ($y=0; $y -lt 32; $y++) {
                for ($x=0; $x -lt 32; $x++) {
                    $a=$bitmap.GetPixel($x,$y); $b=$expected.GetPixel($x,$y)
                    if ($a.A -ne $b.A -or ($a.A -gt 0 -and ($a.R -ne $b.R -or $a.G -ne $b.G -or $a.B -ne $b.B))) { $different++ }
                }
            }
            $bitmap.Save((Join-Path $evidence "$($entry.Name)-icon.png"), [Drawing.Imaging.ImageFormat]::Png)
            if ($different -ne 0) { throw "Icon pixel mismatch: $($entry.Name), $different pixels." }
            $results[$entry.Name] = '32px pixels match approved ICO'
        } finally { $bitmap.Dispose(); $icon.Dispose() }
    }
    $results.version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $PublishDirectory 'HoverPocket.Shell.exe')).ProductVersion
    if (!$results.version.StartsWith('0.2.8')) { throw 'Application version mismatch.' }
    $results.sourceCommit = (& git rev-parse HEAD).Trim()
    $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'icon-receipt.json')
    $results | ConvertTo-Json | Write-Host
} finally { $expected.Dispose(); $expectedIcon.Dispose() }
