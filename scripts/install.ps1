#!/usr/bin/env pwsh
#requires -Version 7.4

param(
    [string]$SourcePath = (Split-Path -Parent $PSScriptRoot),
    [string]$InstallRoot = (Join-Path $HOME '.omniroute'),
    [switch]$Force,
    [switch]$AddToPath,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Assert-ChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )
    $parentPath = Get-NormalizedPath -Path $Parent
    $childPath = Get-NormalizedPath -Path $Child
    $prefix = $parentPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside '$parentPath': $childPath"
    }
}

function Add-UserPathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Entry)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts -contains $Entry) { return $false }
    $updated = (@($parts) + $Entry) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    return $true
}

function Remove-UserPathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Entry)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $updatedParts = @($parts | Where-Object { $_ -ine $Entry })
    if ($updatedParts.Count -eq $parts.Count) { return $false }
    [Environment]::SetEnvironmentVariable('Path', ($updatedParts -join ';'), 'User')
    return $true
}

if ($PSVersionTable.PSVersion -lt [Version]'7.4.0') {
    throw "PowerShell 7.4 or newer is required. Current version: $($PSVersionTable.PSVersion)"
}

$installPath = Get-NormalizedPath -Path $InstallRoot
$homePath = Get-NormalizedPath -Path $HOME
$binPath = Join-Path $installPath 'bin'
Assert-ChildPath -Parent $homePath -Child $installPath

if ($Uninstall) {
    $removedPath = Remove-UserPathEntry -Entry $binPath
    if (Test-Path -LiteralPath $installPath) {
        $resolved = (Resolve-Path -LiteralPath $installPath).Path
        Assert-ChildPath -Parent $homePath -Child $resolved
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    Write-Host "Removed OmniRoute-PS from $installPath"
    if ($removedPath) { Write-Host 'Removed the user PATH entry. Open a new terminal for it to take effect.' }
    exit 0
}

$source = Get-NormalizedPath -Path $SourcePath
$sourceEntry = Join-Path $source 'omniroute.ps1'
if (-not (Test-Path -LiteralPath $sourceEntry -PathType Leaf)) {
    throw "SourcePath does not contain omniroute.ps1: $source"
}
if ((Test-Path -LiteralPath $installPath) -and -not $Force) {
    throw "Install path already exists: $installPath. Re-run with -Force to replace it."
}

$staging = Join-Path $HOME ('.omniroute-staging-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $HOME ('.omniroute-backup-' + [guid]::NewGuid().ToString('N'))
Assert-ChildPath -Parent $homePath -Child $staging
Assert-ChildPath -Parent $homePath -Child $backup

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $staging -Recurse -Force
    }
    $launcherDir = Join-Path $staging 'bin'
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $launcher = Join-Path $launcherDir 'omniroute.cmd'
        $cmdLauncher = @('@echo off', 'pwsh -NoProfile -File "%~dp0..\omniroute.ps1" %*') -join "`n"
        $cmdLauncher | Set-Content -LiteralPath $launcher -Encoding ascii
    }
    else {
        $launcher = Join-Path $launcherDir 'omniroute'
        $shellLauncher = @(
            '#!/usr/bin/env pwsh'
            '$root = Split-Path -Parent $PSScriptRoot'
            '& (Join-Path $root ''../omniroute.ps1'') @args'
            'exit $LASTEXITCODE'
        ) -join "`n"
        $shellLauncher | Set-Content -LiteralPath $launcher -Encoding utf8
        & chmod +x $launcher
    }

    if (Test-Path -LiteralPath $installPath) {
        Move-Item -LiteralPath $installPath -Destination $backup
    }
    Move-Item -LiteralPath $staging -Destination $installPath
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
}
catch {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    if (Test-Path -LiteralPath $backup -and -not (Test-Path -LiteralPath $installPath)) {
        Move-Item -LiteralPath $backup -Destination $installPath
    }
    throw
}

$pathAdded = $false
if ($AddToPath) {
    $pathAdded = Add-UserPathEntry -Entry $binPath
}

Write-Host "Installed OmniRoute-PS to $installPath"
if ($AddToPath) {
    if ($pathAdded) { Write-Host "Added $binPath to the user PATH." }
    else { Write-Host "$binPath is already on the user PATH." }
    Write-Host 'Open a new terminal, then run: omniroute help'
}
else {
    Write-Host "Run: pwsh -File `"$installPath\omniroute.ps1`" help"
}
Write-Host "Uninstall: pwsh -File `"$installPath\scripts\install.ps1`" -Uninstall"
