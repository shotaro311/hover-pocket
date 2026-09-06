$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path $env:RUNNER_TEMP 'hoverpocket-icon-release'
New-Item -ItemType Directory -Force $work | Out-Null
$previousZip = Join-Path $work 'previous.zip'
Invoke-WebRequest 'https://github.com/shotaro311/hover-pocket/releases/download/win-v0.2.7/HoverPocketWin-win-Portable.zip' -OutFile $previousZip
if ((Get-FileHash $previousZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne '97f3d09f9381f5f77cab0f9184759b5d3a255b0544313b66971591d8db58bb6d') {
    throw 'The previous public package checksum did not match.'
}
Expand-Archive $previousZip (Join-Path $work 'previous')
$previousDll = Get-ChildItem (Join-Path $work 'previous') -Recurse -Filter HoverPocket.Shell.dll | Select-Object -First 1
if (!$previousDll) { throw 'Previous application assembly was not found.' }

# Preserve the already-public desktop OAuth configuration without logging its values.
$readerDir = Join-Path $work 'metadata-reader'
New-Item -ItemType Directory $readerDir | Out-Null
@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>
'@ | Set-Content (Join-Path $readerDir 'Reader.csproj')
@'
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text.Json;
using var stream = File.OpenRead(args[0]);
using var pe = new PEReader(stream);
var reader = pe.GetMetadataReader();
var values = new Dictionary<string,string>();
foreach (var handle in reader.GetAssemblyDefinition().GetCustomAttributes()) {
    var attr = reader.GetCustomAttribute(handle);
    if (attr.Constructor.Kind != HandleKind.MemberReference) continue;
    var member = reader.GetMemberReference((MemberReferenceHandle)attr.Constructor);
    if (member.Parent.Kind != HandleKind.TypeReference) continue;
    var type = reader.GetTypeReference((TypeReferenceHandle)member.Parent);
    if (reader.GetString(type.Namespace) != "System.Reflection" || reader.GetString(type.Name) != "AssemblyMetadataAttribute") continue;
    var blob = reader.GetBlobReader(attr.Value);
    if (blob.ReadUInt16() != 1) continue;
    var key = blob.ReadSerializedString();
    var value = blob.ReadSerializedString();
    if (key is "GoogleOAuthClientId" or "GoogleOAuthClientSecret") values[key] = value!;
}
if (values.Count != 2 || values.Values.Any(string.IsNullOrWhiteSpace)) throw new Exception("Required desktop configuration is missing.");
File.WriteAllText(args[1], JsonSerializer.Serialize(values));
'@ | Set-Content (Join-Path $readerDir 'Program.cs')
$configPath = Join-Path $work 'previous-config.json'
dotnet run --project (Join-Path $readerDir 'Reader.csproj') -- $previousDll.FullName $configPath
if ($LASTEXITCODE -ne 0) { throw 'Reading the previous desktop configuration failed.' }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
Write-Host "::add-mask::$($config.GoogleOAuthClientId)"
Write-Host "::add-mask::$($config.GoogleOAuthClientSecret)"
$env:HOVERPOCKET_GOOGLE_CLIENT_ID = $config.GoogleOAuthClientId
$env:HOVERPOCKET_GOOGLE_CLIENT_SECRET = $config.GoogleOAuthClientSecret
$env:HOVERPOCKET_RELEASE_EXPECTED_VERSION = '0.2.8'
try {
    & (Join-Path $PSScriptRoot 'publish_release.ps1')
    $exe = Join-Path $root 'dist\windows\publish\win-x64\0.2.8\HoverPocket.Shell.exe'
    foreach ($check in @('timer', 'ui-model', 'updater', 'ui')) {
        $p = Start-Process -FilePath $exe -ArgumentList @('--verify', $check) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "Verification failed: $check ($($p.ExitCode))" }
    }
    & dotnet run --project (Join-Path $readerDir 'Reader.csproj') -- (Join-Path (Split-Path $exe) 'HoverPocket.Shell.dll') (Join-Path $work 'new-config.json')
    if ($LASTEXITCODE -ne 0) { throw 'New desktop configuration readback failed.' }
    if ((Get-Content (Join-Path $work 'new-config.json') -Raw) -cne (Get-Content $configPath -Raw)) { throw 'Desktop OAuth configuration changed.' }
    & (Join-Path $PSScriptRoot 'verify_icon_release.ps1') -PublishDirectory (Split-Path $exe) -ReleaseDirectory (Join-Path $root 'dist\windows\releases\0.2.8')
    Write-Host 'Previous desktop OAuth configuration preserved; values omitted.'
} finally {
    Remove-Item Env:HOVERPOCKET_GOOGLE_CLIENT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:HOVERPOCKET_GOOGLE_CLIENT_SECRET -ErrorAction SilentlyContinue
}
