#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$SourceScriptPath
)

$ErrorActionPreference = 'Stop'
$payloadNames = @(
    'ChatGPTQuotaPet.exe','ChatGPTQuotaPet.ps1','build-windows.ps1','AppIcon.png',
    'ChatGPTQuotaPet.ico','Install-ChatGPTQuotaPet.ps1','Uninstall-ChatGPTQuotaPet.ps1','install.cmd'
)
$expand = Join-Path $env:SystemRoot 'System32\expand.exe'
$makecab = Join-Path $env:SystemRoot 'System32\makecab.exe'

if (-not ('DashboardResourceApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DashboardResourceApi
{
    [DllImport("kernel32.dll", EntryPoint = "LoadLibraryExW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string fileName, IntPtr file, uint flags);
    [DllImport("kernel32.dll", EntryPoint = "FindResourceExW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindResourceEx(IntPtr module, IntPtr type, string name, ushort language);
    [DllImport("kernel32.dll", EntryPoint = "SizeofResource", SetLastError = true)]
    public static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", EntryPoint = "LoadResource", SetLastError = true)]
    public static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", EntryPoint = "LockResource", SetLastError = true)]
    public static extern IntPtr LockResource(IntPtr resourceData);
    [DllImport("kernel32.dll", EntryPoint = "FreeLibrary", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", EntryPoint = "BeginUpdateResourceW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr BeginUpdateResource(string fileName, [MarshalAs(UnmanagedType.Bool)] bool deleteExistingResources);
    [DllImport("kernel32.dll", EntryPoint = "UpdateResourceW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UpdateResource(IntPtr update, IntPtr type, string name, ushort language,
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 5)] byte[] data, uint dataSize);
    [DllImport("kernel32.dll", EntryPoint = "EndUpdateResourceW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EndUpdateResource(IntPtr update, [MarshalAs(UnmanagedType.Bool)] bool discard);
}
'@
}
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $packageName = 'ChatGPT' + [char]0x989D + [char]0x5EA6 + [char]0x4EEA + [char]0x8868 + [char]0x76D8 + '.exe'
    $PackagePath = Join-Path (Join-Path $PSScriptRoot '..\Packages') $packageName
}
if ([string]::IsNullOrWhiteSpace($SourceScriptPath)) {
    $SourceScriptPath = Join-Path $PSScriptRoot 'ChatGPTQuotaPet.ps1'
}
function Get-CabinetResource([string]$Path) {
    $module = [DashboardResourceApi]::LoadLibraryEx($Path, [IntPtr]::Zero, 2)
    if ($module -eq [IntPtr]::Zero) {
        throw ([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'LoadLibraryExW failed'))
    }
    try {
        $resource = [DashboardResourceApi]::FindResourceEx($module, [IntPtr]10, 'CABINET', [uint16]2052)
        if ($resource -eq [IntPtr]::Zero) {
            throw ([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'CABINET resource not found'))
        }
        $size = [int][DashboardResourceApi]::SizeofResource($module, $resource)
        $loaded = [DashboardResourceApi]::LoadResource($module, $resource)
        $data = [DashboardResourceApi]::LockResource($loaded)
        if ($size -le 0 -or $loaded -eq [IntPtr]::Zero -or $data -eq [IntPtr]::Zero) {
            throw ([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'CABINET resource could not be read'))
        }
        $cabinet = New-Object byte[] $size
        [Runtime.InteropServices.Marshal]::Copy($data, $cabinet, 0, $size)
        return ,$cabinet
    } finally {
        [void][DashboardResourceApi]::FreeLibrary($module)
    }
}

function Set-CabinetResource([string]$Path, [string]$CabinetPath) {
    $cabinet = [IO.File]::ReadAllBytes($CabinetPath)
    $update = [DashboardResourceApi]::BeginUpdateResource($Path, $false)
    if ($update -eq [IntPtr]::Zero) {
        throw ([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'BeginUpdateResourceW failed'))
    }
    try {
        if (-not [DashboardResourceApi]::UpdateResource($update, [IntPtr]10, 'CABINET', [uint16]2052, $cabinet, [uint32]$cabinet.Length)) {
            throw ([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'UpdateResourceW failed'))
        }
        $committed = [DashboardResourceApi]::EndUpdateResource($update, $false)
        $update = [IntPtr]::Zero
        if (-not $committed) {
            throw ([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error(), 'EndUpdateResourceW failed'))
        }
    } finally {
        if ($update -ne [IntPtr]::Zero) {
            [void][DashboardResourceApi]::EndUpdateResource($update, $true)
        }
    }
}

function Get-CabinetNames([byte[]]$Cabinet) {
    if ($Cabinet.Length -lt 36 -or [Text.Encoding]::ASCII.GetString($Cabinet, 0, 4) -ne 'MSCF') {
        throw 'Invalid CAB header.'
    }
    if ([BitConverter]::ToUInt32($Cabinet, 8) -ne $Cabinet.Length -or
        [BitConverter]::ToUInt16($Cabinet, 26) -ne 1 -or
        [BitConverter]::ToUInt16($Cabinet, 30) -ne 0) {
        throw 'Unsupported CAB layout; expected the original single-folder IExpress package.'
    }
    $position = [long][BitConverter]::ToUInt32($Cabinet, 16)
    $fileCount = [int][BitConverter]::ToUInt16($Cabinet, 28)
    if ($position -lt 36 -or $position -ge $Cabinet.Length) { throw 'Invalid CAB file table.' }
    $stream = [IO.MemoryStream]::new($Cabinet, $false)
    $reader = [IO.BinaryReader]::new($stream)
    $names = New-Object 'System.Collections.Generic.List[string]'
    try {
        $stream.Position = $position
        for ($i = 0; $i -lt $fileCount; $i++) {
            if ($stream.Position + 16 -gt $stream.Length) { throw 'Truncated CAB file table.' }
            $null = $reader.ReadBytes(16)
            $nameBytes = New-Object 'System.Collections.Generic.List[byte]'
            $terminated = $false
            while ($stream.Position -lt $stream.Length) {
                $byte = $reader.ReadByte()
                if ($byte -eq 0) { $terminated = $true; break }
                $nameBytes.Add($byte)
            }
            if (-not $terminated) { throw 'Unterminated CAB filename.' }
            $name = [Text.Encoding]::ASCII.GetString($nameBytes.ToArray())
            if ($name -notmatch '^[A-Za-z0-9._-]+$' -or $names.Contains($name)) {
                throw "Unsafe or duplicate CAB filename: $name"
            }
            $names.Add($name)
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    return $names.ToArray()
}

function Expand-IExpressPackage([string]$Package, [string]$Destination) {
    $cab = Get-CabinetResource $Package
    $names = @(Get-CabinetNames $cab | Sort-Object)
    $expected = @($payloadNames | Sort-Object)
    if ($names.Count -ne $expected.Count) { throw "Package has $($names.Count) payload files; expected $($expected.Count)." }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($names[$i] -cne $expected[$i]) { throw "Unexpected CAB payload: $($names[$i])" }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $cabPath = Join-Path $Destination 'payload.cab'
    [IO.File]::WriteAllBytes($cabPath, $cab)
    & $expand '-F:*' $cabPath $Destination | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "expand.exe failed with exit code $LASTEXITCODE." }
    foreach ($name in $payloadNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Leaf)) {
            throw "CAB extraction did not produce $name."
        }
    }
}

foreach ($path in @($PackagePath, $SourceScriptPath, $expand, $makecab)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file is missing: $path" }
}
$package = [IO.Path]::GetFullPath($PackagePath)
$source = [IO.Path]::GetFullPath($SourceScriptPath)
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$work = Join-Path $root ('.build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)).TrimEnd('\') -ine $root) {
    throw 'Temporary work directory is not a direct child of the coding directory.'
}
$hadPackage = Test-Path -LiteralPath $package -PathType Leaf
$replaced = $false

try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $payload = Join-Path $work 'payload'
    $verify = Join-Path $work 'verify'
    Expand-IExpressPackage $package $payload
    $originalHashes = @{}
    foreach ($name in $payloadNames) {
        $originalHashes[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $payload $name)).Hash
    }
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    Copy-Item -LiteralPath $source -Destination (Join-Path $payload 'ChatGPTQuotaPet.ps1') -Force

    $staged = Join-Path $work 'chatgpt-quota-dashboard.exe'
    $cab = Join-Path $work 'payload.cab'
    $ddf = Join-Path $work 'payload.ddf'
    $ddfLines = @(
        '.OPTION EXPLICIT',
        '.Set Cabinet=ON',
        '.Set Compress=ON',
        '.Set CompressionType=MSZIP',
        '.Set MaxDiskSize=0',
        '.Set FolderSizeThreshold=2147483647',
        ('.Set DiskDirectoryTemplate=' + $work),
        '.Set CabinetNameTemplate=payload.cab',
        ('.Set InfFileName=' + (Join-Path $work 'payload.inf')),
        ('.Set RptFileName=' + (Join-Path $work 'payload.rpt'))
    )
    foreach ($name in $payloadNames) {
        $ddfLines += ('"' + (Join-Path $payload $name) + '" "' + $name + '"')
    }
    [IO.File]::WriteAllLines($ddf, $ddfLines, [Text.Encoding]::ASCII)
    & $makecab '/F' $ddf | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $cab -PathType Leaf)) {
        throw "makecab.exe failed (exit code $LASTEXITCODE)."
    }
    Copy-Item -LiteralPath $package -Destination $staged
    Set-CabinetResource $staged $cab
    Expand-IExpressPackage $staged $verify
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $verify 'ChatGPTQuotaPet.ps1')).Hash -cne $sourceHash) {
        throw 'Repackaged ChatGPTQuotaPet.ps1 does not match the source hash.'
    }
    foreach ($name in $payloadNames) {
        if ($name -cne 'ChatGPTQuotaPet.ps1' -and
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $verify $name)).Hash -cne $originalHashes[$name]) {
            throw "Repackaging changed an unrelated payload: $name"
        }
    }

    $stagedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $staged).Hash
    try {
        if ($hadPackage) {
            [IO.File]::Replace($staged, $package, (Join-Path $work 'previous-package.exe'), $true)
        } else {
            [IO.File]::Move($staged, $package)
        }
        $replaced = $true
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash -cne $stagedHash) {
            throw 'Published package hash differs from the verified build.'
        }
    } catch {
        if ($replaced -and $hadPackage -and (Test-Path -LiteralPath (Join-Path $work 'previous-package.exe'))) {
            [IO.File]::Replace((Join-Path $work 'previous-package.exe'), $package, (Join-Path $work 'failed-package.exe'), $true)
        } elseif ($replaced -and -not $hadPackage -and (Test-Path -LiteralPath $package)) {
            Remove-Item -LiteralPath $package -Force
        }
        throw
    }

    [pscustomobject]@{
        Package = $package
        PackageSha256 = $stagedHash
        MainScriptSha256 = $sourceHash
        PreservedPayloadFiles = $payloadNames.Count - 1
        Verified = $true
    }
} finally {
    if (Test-Path -LiteralPath $work -PathType Container) {
        $resolvedWork = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $work).Path).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolvedWork).TrimEnd('\') -ine $root -or
            -not [IO.Path]::GetFileName($resolvedWork).StartsWith('.build-', [StringComparison]::Ordinal)) {
            throw "Refusing to recursively remove unexpected path: $resolvedWork"
        }
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}
