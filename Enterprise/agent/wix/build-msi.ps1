# build-msi.ps1 - produces IT-Toolkit-Agent.msi.
#
# Stages the built agent exe, its config, and the toolkit files it wraps into
# wix\stage\ (the WXS references stage\...), then invokes WiX.
#
# Prereqs: WiX v5 toolset (`dotnet tool install --global wix --version "5.*"`).
# (WiX v7 requires accepting the OSMF EULA; v5 is MIT and uses the same v4 WXS schema.)
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

# Bundle the official sqlite3.exe CLI so the agent's outbox queue works on
# stock Windows with no system-wide SQLite install. The agent prepends this
# directory to PATH at startup (see Agent-Collect.ps1), which the shared
# ToolkitData module's `sqlite3` lookups then pick up.
$sqliteVer = '3530400'
$sqliteUrl  = "https://www.sqlite.org/2026/sqlite-tools-win-x64-$sqliteVer.zip"
$stageSqlite = Join-Path $Stage 'sqlite3.exe'
if (-not (Test-Path $stageSqlite)) {
    Write-Host "Downloading sqlite3.exe ($sqliteUrl)"
    $sqliteZip  = Join-Path $env:TEMP "sqlite-tools-win-x64-$sqliteVer.zip"
    $extractDir = Join-Path $env:TEMP "sqlite-tools-win-x64-$sqliteVer"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    try {
        Invoke-WebRequest $sqliteUrl -OutFile $sqliteZip -UseBasicParsing
        Expand-Archive $sqliteZip -DestinationPath $extractDir -Force
        Copy-Item (Join-Path $extractDir "sqlite-tools-win-x64-$sqliteVer\sqlite3.exe") $stageSqlite -Force
    }
    finally {
        if (Test-Path $sqliteZip)  { Remove-Item $sqliteZip -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Test-Path $stageSqlite)) { throw "Failed to fetch sqlite3.exe from $sqliteUrl" }
}
Write-Host "Staged sqlite3.exe ($($(Get-Item $stageSqlite).Length) bytes)"

# bundle the toolkit files the agent wraps (scripts + modules + config)
Copy-Item (Join-Path $RepoRoot 'Scripts') (Join-Path $Stage 'Scripts') -Recurse -Force
Copy-Item (Join-Path $RepoRoot 'Config')  (Join-Path $Stage 'Config')  -Recurse -Force

# E4: on-demand elevated helper (registers ITToolkitAgentElevated with a
# security descriptor that lets the NETWORK SERVICE agent trigger it).
Copy-Item (Join-Path $WixDir 'Create-ElevatedTask.ps1') (Join-Path $Stage 'Scripts\Create-ElevatedTask.ps1') -Force

# bundle the support-engineer collectors (installed as <root>\Enterprise\agent\collectors\,
# same relative path the agent.json feature scripts use in the repo)
$collectors = Join-Path $RepoRoot 'Enterprise\agent\collectors'
if (Test-Path $collectors) {
    $stageCollectors = Join-Path $Stage 'Enterprise\agent\collectors'
    New-Item -ItemType Directory -Path $stageCollectors -Force | Out-Null
    Copy-Item (Join-Path $collectors '*.ps1') $stageCollectors -Force
}

$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) { throw "WiX toolset not found. Install: dotnet tool install --global wix" }

# Agent version + interval come from agent/agent-version.json (single source of
# truth, A2). WiX preprocessor vars are injected here so the MSI product code
# and scheduled-task interval never drift from bundle.py / deploy scripts.
$metaRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$agentMeta = Get-Content (Join-Path $metaRoot 'agent\agent-version.json') -Raw | ConvertFrom-Json
$AgentVersion = [string]$agentMeta.agent_version
$AgentInterval = [string]$agentMeta.interval_minutes

# MSI upgrade path (A3): Windows Installer refuses upgrades to an equal or
# lower ProductVersion, and <MajorUpgrade> compares on the whole 4-part number.
# So we keep UpgradeCode stable and stamp a monotonic build revision on top of
# the semver:  <major>.<minor>.<patch>.<days-since-epoch>.  Any release made on
# a later day (or after bumping agent-version.json) therefore upgrades cleanly.
$verParts = ($AgentVersion -split '\.')
$maj = [int]($verParts[0] -replace '[^0-9]', '')
$min = if ($verParts.Count -gt 1) { [int]($verParts[1] -replace '[^0-9]', '') } else { 0 }
$pat = if ($verParts.Count -gt 2) { [int]($verParts[2] -replace '[^0-9]', '') } else { 0 }
if ($verParts.Count -gt 3) { $pat = [int]($verParts[3] -replace '[^0-9]', '') }
$days = [int][math]::Floor((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalDays)
$MsiVersion = "$maj.$min.$pat.$days"
Write-Host "Baking AgentVersion=$AgentVersion AgentInterval=$AgentInterval MsiVersion=$MsiVersion"

# Run wix from the WXS directory so its relative Source paths (stage\...) resolve
# against the WXS location regardless of the caller's working directory.
Push-Location $WixDir
try {
    & $wix.Source build 'Agent.wxs' -o "$(Join-Path $BuildOut 'IT-Toolkit-Agent.msi')" -d "AgentVersion=$MsiVersion" -d "AgentInterval=$AgentInterval"
    if ($LASTEXITCODE -ne 0) { throw "WiX build failed with exit code $LASTEXITCODE (see output above)" }
}
finally {
    Pop-Location
}

if (-not (Test-Path (Join-Path $BuildOut 'IT-Toolkit-Agent.msi'))) {
    throw "WiX build reported success but no MSI was produced at $BuildOut\IT-Toolkit-Agent.msi"
}

Write-Host "MSI built: $BuildOut\IT-Toolkit-Agent.msi"
Write-Host "Deploy with: msiexec /i IT-Toolkit-Agent.msi /qn   (or push via Intune/GPO/SCCM)"
