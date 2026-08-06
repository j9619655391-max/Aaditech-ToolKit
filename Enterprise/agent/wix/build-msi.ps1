# build-msi.ps1 - produces IT-Toolkit-Agent.msi.
#
# Stages the built agent exe, its config, and the toolkit files it wraps into
# wix\stage\ (the WXS references stage\...), then invokes WiX.
#
# Prereqs: WiX v4 toolset (`dotnet tool install --global wix`).
# Steps:
#   1. run Enterprise/agent/build/build-agent.ps1  (produces build/out/)
#   2. run this script                               (produces build/out/IT-Toolkit-Agent.msi)

[CmdletBinding()]
param(
    [string]$BuildOut = "$PSScriptRoot\..\build\out",
    [string]$WixDir = $PSScriptRoot,
    [string]$RepoRoot = "$PSScriptRoot\..\..\.."
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $BuildOut 'IT-Toolkit-Agent.exe'))) {
    throw "build/out/IT-Toolkit-Agent.exe missing. Run build-agent.ps1 first."
}
if (-not (Test-Path (Join-Path $BuildOut 'agent-config.json'))) {
    throw "build/out/agent-config.json missing. Run build-agent.ps1 first."
}

$Stage = Join-Path $WixDir 'stage'
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

Copy-Item (Join-Path $BuildOut 'IT-Toolkit-Agent.exe') (Join-Path $Stage 'IT-Toolkit-Agent.exe') -Force
Copy-Item (Join-Path $BuildOut 'agent-config.json') (Join-Path $Stage 'agent.json') -Force

# bundle the toolkit files the agent wraps (scripts + modules + config)
Copy-Item (Join-Path $RepoRoot 'Scripts') (Join-Path $Stage 'Scripts') -Recurse -Force
Copy-Item (Join-Path $RepoRoot 'Config')  (Join-Path $Stage 'Config')  -Recurse -Force

$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) { throw "WiX toolset not found. Install: dotnet tool install --global wix" }

& $wix.Source build "$(Join-Path $WixDir 'Agent.wxs')" -o "$(Join-Path $BuildOut 'IT-Toolkit-Agent.msi')"

Write-Host "MSI built: $BuildOut\IT-Toolkit-Agent.msi"
Write-Host "Deploy with: msiexec /i IT-Toolkit-Agent.msi /qn   (or push via Intune/GPO/SCCM)"
