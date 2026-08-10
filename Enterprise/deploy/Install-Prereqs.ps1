<#
Install-Prereqs.ps1 - one-command prerequisite INSTALLER for a fresh Windows
Server before running deploy.ps1 (IT-Toolkit Enterprise).

WHY THIS EXISTS:
The prerequisite scanner (Enterprise/tests/Check-Deploy-Prereqs.ps1) only
CHECKS the machine. This script INSTALLS everything a fresh Windows Server
needs so `deploy.ps1` can run end-to-end, including building the agent .exe
(ps2exe) and .msi (WiX v5) locally:

  - Git CLI
  - Docker Desktop (WSL2 backend) + compose v2 plugin
  - WSL2 (VirtualMachinePlatform + WSL subsystem) for Docker Linux containers
  - .NET SDK (WiX v5 ships as a dotnet global tool)
  - ps2exe PowerShell module (Windows PowerShell 5.1 only - see below)
  - wix dotnet global tool
  - optional: Windows SDK signtool (artifacts stay UNSIGNED without it)
  - execution policy + admin checks

CRITICAL (ps2exe):
MScholtes/PS2EXE targets the .NET Framework compiler and ONLY works under
Windows PowerShell 5.1. It fails under pwsh (PowerShell 7). This script
installs it via `powershell.exe -Command Install-Module ...` so it lands in
the 5.1 module path, and deploy.ps1's build-agent.ps1 re-execs under 5.1.

REBOOT:
Enabling WSL2 / installing Docker Desktop typically requires a reboot. The
script sets a $rebootRequired flag and tells you to reboot before the next
step. Run this script twice: once to install, reboot, then re-run (it is
idempotent - already-installed items are skipped) and it will verify Docker
with `docker run hello-world`.

Usage (run as Administrator):
  pwsh ./Enterprise/deploy/Install-Prereqs.ps1            # install everything
  pwsh ./Enterprise/deploy/Install-Prereqs.ps1 -SkipDocker  # server only, no Docker
  pwsh ./Enterprise/deploy/Install-Prereqs.ps1 -IncludeSdk  # also install Windows SDK
  pwsh ./Enterprise/deploy/Install-Prereqs.ps1 -VerifyOnly  # check, install nothing

Exit codes:
  0 = ready to run deploy.ps1 (or nothing to do)
  1 = not elevated (cannot install)
  2 = installed something that needs a reboot before deploy.ps1
  3 = a blocker remains after install (see output)
#>

[CmdletBinding()]
param(
    [switch]$SkipDocker,   # skip Docker Desktop + WSL2 (e.g. Docker already works)
    [switch]$IncludeSdk,   # also install Windows SDK (signtool for code signing)
    [switch]$VerifyOnly,   # check only; do not install anything
    [string]$WingetIdGit  = 'Git.Git',
    [string]$WingetIdDocker = 'Docker.DockerDesktop',
    [string]$WingetIdDotnet = 'Microsoft.DotNet.SDK.8'
)

$ErrorActionPreference = 'Stop'
$rebootRequired = $false
$warnings = [System.Collections.Generic.List[string]]::new()

function Log  { Write-Host "[prereq] $args" -ForegroundColor Cyan }
function Warn { Write-Host "[prereq][WARN] $args" -ForegroundColor Yellow }
function Ok   { Write-Host "[prereq][OK]   $args" -ForegroundColor Green }

# ---------------------------------------------------------------- platform guard

$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
if (-not $onWindows) {
    Write-Host "[prereq][ERROR] This installer targets Windows Server (Docker Desktop, WSL2, ps2exe, WiX)." -ForegroundColor Red
    Write-Host "  On macOS/Linux run:  pwsh ./Enterprise/tests/Check-Deploy-Prereqs.ps1 -ForServerLinux" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- elevation

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated  = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    Write-Host "[prereq][ERROR] This script installs software system-wide and must run as Administrator." -ForegroundColor Red
    Write-Host "  Right-click PowerShell -> 'Run as administrator', then re-run." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- execution policy

$cur = (Get-ExecutionPolicy -Scope CurrentUser)
if ($cur -eq 'Restricted' -or $cur -eq 'AllSigned') {
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    Log "Execution policy changed: $cur -> RemoteSigned (CurrentUser)"
} else {
    Log "Execution policy OK: $cur"
}

function Get-CommandPath {
    param([string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param([string]$Id, [string]$Display)
    Log "Installing $Display ($Id) via winget..."
    winget install -e --id $Id --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 0x8A150011) {
        # 0x8A150011 = already installed / another version present
        Warn "$Display install returned code $LASTEXITCODE - continuing"
    }
}

# ---------------------------------------------------------------- 1. Git

$git = Get-CommandPath 'git'
if ($git) {
    Ok "Git already installed: $git"
} elseif ($VerifyOnly) {
    Warn "Git missing - would run: winget install -e --id $WingetIdGit"
} elseif (-not (Test-Winget)) {
    Warn "winget not available - install Git manually from https://git-scm.com/download/win"
} else {
    Install-WingetPackage -Id $WingetIdGit -Display "Git"
}

# ---------------------------------------------------------------- 2. WSL2 + Docker

if (-not $SkipDocker) {
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    $vmFeature  = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

    if ($wslFeature -and $wslFeature.State -ne 'Enabled') {
        if ($VerifyOnly) {
            Warn 'WSL feature disabled - would run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart'
        } else {
            Log 'Enabling WSL feature (Microsoft-Windows-Subsystem-Linux)...'
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All | Out-Null
            $rebootRequired = $true
        }
    }
    if ($vmFeature -and $vmFeature.State -ne 'Enabled') {
        if ($VerifyOnly) {
            Warn 'VirtualMachinePlatform feature disabled - would run: Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart'
        } else {
            Log 'Enabling VirtualMachinePlatform feature...'
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All | Out-Null
            $rebootRequired = $true
        }
    }

    $docker = Get-CommandPath 'docker'
    $composeOk = $false
    if ($docker) {
        $composeVer = (& docker compose version 2>$null | Out-String).Trim()
        $composeOk = [bool]$composeVer
    }
    if ($docker -and $composeOk) {
        Ok "Docker + compose v2 already installed: $composeVer"
    } elseif ($VerifyOnly) {
        Warn "Docker Desktop missing - would run: winget install -e --id $WingetIdDocker"
    } elseif (-not (Test-Winget)) {
        Warn "winget not available - install Docker Desktop manually from https://www.docker.com/products/docker-desktop/"
    } else {
        Install-WingetPackage -Id $WingetIdDocker -Display "Docker Desktop"
        $rebootRequired = $true
    }
} else {
    Log 'Skipping Docker + WSL2 install (-SkipDocker)'
}

# ---------------------------------------------------------------- 3. .NET SDK (WiX)

$dotnet = Get-CommandPath 'dotnet'
if ($dotnet) {
    Ok "dotnet already installed: $dotnet"
} elseif ($VerifyOnly) {
    Warn ".NET SDK missing - would run: winget install -e --id $WingetIdDotnet"
} elseif (-not (Test-Winget)) {
    Warn "winget not available - install .NET SDK manually: https://dotnet.microsoft.com/download"
} else {
    Install-WingetPackage -Id $WingetIdDotnet -Display ".NET SDK"
}

# ---------------------------------------------------------------- 4. ps2exe (5.1 ONLY)

# Must install under Windows PowerShell 5.1 (pwsh 7 will happily install the
# module but it will fail at build time). Re-exec powershell.exe.
$ps51Exe = "${env:SystemRoot}\System32\WindowsPowerShell\v1.0\powershell.exe"
$ps2exe51 = & $ps51Exe -NoProfile -Command "(Get-Module ps2exe -ListAvailable | Select-Object -First 1).Version.ToString()"
if ($LASTEXITCODE -eq 0 -and $ps2exe51) {
    Ok "ps2exe installed for Windows PowerShell 5.1: $ps2exe51"
} elseif ($VerifyOnly) {
    Warn 'ps2exe module missing (5.1) - would run: powershell.exe -Command "Install-Module ps2exe -Scope CurrentUser -Force"'
} else {
    Log 'Installing ps2exe module under Windows PowerShell 5.1...'
    & $ps51Exe -NoProfile -ExecutionPolicy RemoteSigned -Command "Install-Module ps2exe -Scope CurrentUser -Force"
    if ($LASTEXITCODE -ne 0) {
        Warn "ps2exe install returned exit code $LASTEXITCODE"
        $warnings.Add('ps2exe install failed - agent .exe build will fail; try: Install-Module ps2exe -Scope CurrentUser -Force')
    }
}

# ---------------------------------------------------------------- 5. wix dotnet tool

if ($dotnet) {
    $wix = Get-Command wix -ErrorAction SilentlyContinue
    if ($wix) {
        Ok "WiX toolset already installed: $($wix.Source)"
    } elseif ($VerifyOnly) {
        Warn 'WiX toolset missing - would run: dotnet tool install --global wix --version "5.*"'
    } else {
        Log 'Installing WiX toolset (dotnet global tool)...'
        dotnet tool install --global wix --version "5.*" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Warn "wix install returned exit code $LASTEXITCODE"
            $warnings.Add('WiX install failed - MSI build will fail; try: dotnet tool install --global wix --version "5.*"')
        }
    }
} else {
    Warn 'dotnet missing - cannot install WiX toolset'
}

# ---------------------------------------------------------------- 6. optional: signtool

if ($IncludeSdk) {
    $sdk = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $signtool = $null
    if (Test-Path $sdk) {
        $signtool = Get-ChildItem $sdk -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\d+\.\d+\.\d+\.\d+\\x64' } |
            Sort-Object FullName -Descending | Select-Object -First 1
    }
    if ($signtool) {
        Ok "signtool already present: $($signtool.FullName)"
    } elseif ($VerifyOnly) {
        Warn 'Windows SDK missing - would run: winget install -e --id Microsoft.WindowsSDK'
    } elseif (Test-Winget) {
        Install-WingetPackage -Id "Microsoft.WindowsSDK" -Display "Windows SDK"
    } else {
        Warn 'winget not available - install Windows SDK manually (optional: MSI ships unsigned otherwise)'
    }
} else {
    Log 'Skipping Windows SDK (-IncludeSdk not passed; MSI will ship UNSIGNED - deploy.ps1 warns)'
}

# ---------------------------------------------------------------- 7. path check

$repoRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $repoRoot
if ($repoRoot -match ' ') {
    Warn "Repo path contains spaces: $repoRoot - MSI/WiX/ps2exe are fragile with spaces; copy to e.g. C:\IT-Toolkit"
    $warnings.Add('Repo path has spaces - move to C:\IT-Toolkit before deploy.ps1')
} else {
    Ok "Repo path OK: $repoRoot"
}

# ---------------------------------------------------------------- 8. summary

Write-Host ""
Write-Host ("-" * 70)
Write-Host "Prerequisite install summary"
Write-Host ("-" * 70)

$stillMissing = @()
foreach ($item in 'git','docker','dotnet','wix','ps2exe') {
    $present = switch ($item) {
        'git'    { [bool](Get-CommandPath 'git') }
        'docker' { [bool](Get-CommandPath 'docker') }
        'dotnet' { [bool](Get-CommandPath 'dotnet') }
        'wix'    { [bool](Get-Command wix -ErrorAction SilentlyContinue) }
        'ps2exe' {
            $v = & $ps51Exe -NoProfile -Command "(Get-Module ps2exe -ListAvailable | Select-Object -First 1)" 2>$null
            [bool]$v
        }
    }
    if (-not $present) { $stillMissing += $item }
}

if ($stillMissing.Count -eq 0) {
    Ok "All required tools present: git, docker+compose, dotnet, wix, ps2exe"
} else {
    Warn "Still missing: $($stillMissing -join ', ')"
}
foreach ($w in $warnings) { Warn $w }

if ($rebootRequired) {
    Write-Host ""
    Write-Host "[prereq] A reboot is required before running deploy.ps1 (WSL2/Docker changed)." -ForegroundColor Yellow
    Write-Host "  Reboot, then RE-RUN this script to verify Docker, then run deploy.ps1." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Next: Restart-Computer   (then re-run this script, then:)  pwsh ./Enterprise/deploy/deploy.ps1" -ForegroundColor Cyan
    exit 2
}

if ($stillMissing.Count -gt 0) { exit 3 }
Write-Host ""
Write-Host "Ready. Next: pwsh ./Enterprise/deploy/deploy.ps1" -ForegroundColor Green
exit 0
