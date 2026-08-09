<#
 Check-Deploy-Prereqs.ps1 - scan a machine for everything the IT-Toolkit
 Enterprise deployment needs, then emit a machine-readable report.

 WHY THIS EXISTS (AI-agent friendly):
 The deployment path differs by host (Windows Server = deploy.ps1 local build,
 macOS/Linux = deploy.sh + GitHub remote build, agent-only test box = none of
 those). Instead of guessing, an AI agent should run THIS script first, read
 the JSON it produces, and pick the deployment path that the host supports.

 Usage:
   pwsh ./Enterprise/tests/Check-Deploy-Prereqs.ps1
       -ReportPath  <path to JSON report>      (default: ./prereq-report.json)
       -ShowTable                               (also print the human table)
       -JsonOnly                                (no table, just the report)
       -ForAgentBox                             (target: test/agent-only box)
       -ForServerWindows                        (target: deploy.ps1 local build)
       -ForServerLinux                          (target: deploy.sh + GitHub build)

 Exit code:
   0 = no blockers (may still have warnings)
   1 = at least one BLOCKER missing (deployment cannot proceed for the target)

 Report JSON shape (one entry per check):
   {
     "target": "server-windows",
     "checked_at": "ISO8601",
     "os": {"platform":"Darwin","machine":"x86_64","version":"...","elevated":false},
     "overall": {"blockers":0,"warnings":2,"ok":9,"decision":"server-linux-or-mac"},
     "checks":[
        {"id":"git","name":"Git CLI","status":"ok","required_for":["server-windows","server-linux","agent-box"],"detail":"/usr/bin/git","fix":null},
        {"id":"ps2exe","name":"ps2exe PowerShell module","status":"missing","required_for":["server-windows"],"detail":"...","fix":"Install-Module ps2exe -Scope CurrentUser -Force"}
     ]
   }

 "status" is one of: ok | missing (blocker) | warn (advisory) | n/a (not required
 for the chosen target).
#>

[CmdletBinding()]
param(
    [string]$ReportPath = (Join-Path (Get-Location) 'prereq-report.json'),
    [switch]$ShowTable,
    [switch]$JsonOnly,
    [switch]$ForAgentBox,
    [switch]$ForServerWindows,
    [switch]$ForServerLinux
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-CommandPath {
    param([string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# ---------------------------------------------------------------- target decision

$isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$isMac     = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
$isLinux   = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)

if ($ForAgentBox)      { $target = 'agent-box' }
elseif ($ForServerWindows) { $target = 'server-windows' }
elseif ($ForServerLinux)   { $target = 'server-linux' }
else {
    if ($isWindows) { $target = 'server-windows' }
    elseif ($isLinux -or $isMac) { $target = 'server-linux' }
    else { $target = 'agent-box' }
}

# ---------------------------------------------------------------- OS / identity

$osPlatform = if ($isWindows) { 'Windows' } elseif ($isMac) { 'macOS' } elseif ($isLinux) { 'Linux' } else { 'Unknown' }
$elevated = $false
if ($isWindows) {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $elevated = $false }
}

$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [string]$Id, [string]$Name, [string]$Status,
        [string[]]$RequiredFor, [string]$Detail, [string]$Fix
    )
    $checks.Add([pscustomobject]@{
        id = $Id; name = $Name; status = $Status;
        required_for = $RequiredFor; detail = $Detail; fix = $Fix
    })
}

function Test-RequiredFor {
    param([string[]]$RequiredFor)
    return ($RequiredFor -contains $target)
}

# ---------------------------------------------------------------- 1. base tools

$git = Get-CommandPath 'git'
$status = if ($git) { 'ok' } elseif (Test-RequiredFor @('server-windows','server-linux','agent-box')) { 'missing' } else { 'n/a' }
$fix = if ($status -eq 'missing') { 'winget install --id Git.Git -e (Windows) | brew install git (macOS) | apt install git (Linux)' } else { $null }
Add-Check -Id 'git' -Name 'Git CLI' -Status $status -RequiredFor @('server-windows','server-linux','agent-box') -Detail $git -Fix $fix

$python = Get-CommandPath 'python3'
if (-not $python) { $python = Get-CommandPath 'python' }
$status = if ($python) { 'ok' } elseif (Test-RequiredFor @('server-linux')) { 'missing' } else { 'n/a' }
$fix = if ($status -eq 'missing') { 'Install Python 3.10+ (https://www.python.org) — deploy.sh uses it to render agent-config.json' } else { $null }
Add-Check -Id 'python3' -Name 'Python 3' -Status $status -RequiredFor @('server-linux','server-windows') -Detail $python -Fix $fix

$openssl = Get-CommandPath 'openssl'
$status = if ($openssl) { 'ok' } elseif (Test-RequiredFor @('server-windows','server-linux')) { 'missing' } else { 'n/a' }
$fix = if ($status -eq 'missing') { 'deploy.ps1 needs openssl to verify the :9443 cert (Git for Windows bundles it). Install Git or OpenSSL.' } else { $null }
Add-Check -Id 'openssl' -Name 'OpenSSL CLI' -Status $status -RequiredFor @('server-windows','server-linux') -Detail $openssl -Fix $fix

# ---------------------------------------------------------------- 2. docker (server only)

$docker = Get-CommandPath 'docker'
$dockerVer = $null
if ($docker) { $dockerVer = (& docker --version 2>$null | Out-String).Trim() }
$dockerOk = $false
$composeVer = $null
if ($docker) {
    $composeVer = (& docker compose version 2>$null | Out-String).Trim()
    $dockerOk = [bool]$composeVer
}
$requiredDocker = @('server-windows','server-linux')
$status = if ($docker -and $dockerOk) { 'ok' }
          elseif ($docker -and -not $dockerOk) { 'warn' }
          elseif (Test-RequiredFor $requiredDocker) { 'missing' }
          else { 'n/a' }
$fix = if ($status -eq 'missing') {
    'Windows: install Docker Desktop (WSL2 backend) — winget install Docker.DockerDesktop. macOS/Linux: see https://docs.docker.com/engine/install/'
} elseif ($status -eq 'warn') {
    'docker is installed but `docker compose version` failed — install the compose v2 plugin or upgrade Docker Desktop.'
} else { $null }
Add-Check -Id 'docker' -Name 'Docker + compose v2' -Status $status -RequiredFor $requiredDocker -Detail $dockerVer -Fix $fix

# ---------------------------------------------------------------- 3. build toolchain (server-windows local build)

$ps2exe = Get-Module ps2exe -ListAvailable | Select-Object -First 1
$status = if ($ps2exe) { 'ok' } elseif (Test-RequiredFor @('server-windows')) { 'missing' } else { 'n/a' }
$fix = if ($status -eq 'missing') { 'Install-Module ps2exe -Scope CurrentUser -Force  (deploy.ps1 auto-installs it)' } else { $null }
Add-Check -Id 'ps2exe' -Name 'ps2exe module' -Status $status -RequiredFor @('server-windows') -Detail $(if ($ps2exe) { $ps2exe.Version.ToString() } else { $null }) -Fix $fix

$dotnet = Get-CommandPath 'dotnet'
$status = if ($dotnet) { 'ok' } elseif (Test-RequiredFor @('server-windows')) { 'missing' } else { 'n/a' }
$fix = if ($status -eq 'missing') { 'WiX v5 ships as a dotnet tool. Install the .NET SDK: winget install Microsoft.DotNet.SDK.8' } else { $null }
Add-Check -Id 'dotnet' -Name '.NET SDK (dotnet)' -Status $status -RequiredFor @('server-windows') -Detail $dotnet -Fix $fix

$wix = Get-CommandPath 'wix'
$status = if ($wix) { 'ok' } elseif (Test-RequiredFor @('server-windows')) { 'missing' } else { 'n/a' }
$fix = if ($status -eq 'missing') { 'dotnet tool install --global wix --version "5.*"  (deploy.ps1 auto-installs it)' } else { $null }
Add-Check -Id 'wix' -Name 'WiX v5 toolset' -Status $status -RequiredFor @('server-windows') -Detail $wix -Fix $fix

# Windows SDK / signtool (optional - artifacts stay unsigned but deploy works)
$signtool = $null
if ($isWindows) {
    $sdk = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $signtool = Get-ChildItem $sdk -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\d+\.\d+\.\d+\.\d+\\x64' } |
        Sort-Object FullName -Descending | Select-Object -First 1
}
$status = if ($signtool) { 'ok' } elseif (Test-RequiredFor @('server-windows')) { 'warn' } else { 'n/a' }
$fix = if ($status -eq 'warn') { 'winget install Microsoft.WindowsSDK  (optional: without signtool the MSI ships UNSIGNED)' } else { $null }
Add-Check -Id 'signtool' -Name 'Windows SDK signtool' -Status $status -RequiredFor @('server-windows') -Detail $(if ($signtool) { $signtool.FullName } else { $null }) -Fix $fix

# ---------------------------------------------------------------- 4. Windows-specific

$repoRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $repoRoot
$pathHasSpace = $repoRoot -match ' '
$status = if ($pathHasSpace) { 'warn' } else { 'ok' }
Add-Check -Id 'path-nospace' -Name 'Repo path has no spaces' -Status $status -RequiredFor @('server-windows','agent-box') -Detail $repoRoot -Fix 'Copy the repo to a path without spaces (e.g. C:\IT-Toolkit). MSI/WiX/ps2exe are fragile with spaces.'

if ($isWindows) {
    $execPolicy = (Get-ExecutionPolicy -Scope CurrentUser)
    $status = if ($execPolicy -eq 'Restricted' -or $execPolicy -eq 'AllSigned') { 'warn' } else { 'ok' }
    $fix = if ($status -eq 'warn') { 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned  (unsigned scripts need this)' } else { $null }
    Add-Check -Id 'execution-policy' -Name 'Execution policy' -Status $status -RequiredFor @('server-windows','agent-box') -Detail $execPolicy -Fix $fix

    $status = if ($elevated) { 'ok' } else { 'warn' }
    Add-Check -Id 'admin' -Name 'Elevated (admin) PowerShell' -Status $status -RequiredFor @('server-windows') -Detail $(if ($elevated) { 'admin' } else { 'not elevated' }) -Fix 'deploy.ps1 does not strictly require elevation (Docker install + module install do). Prefer an elevated shell for the first run.'
}

# ---------------------------------------------------------------- 5. ports (server)

$busyPorts = @()
foreach ($port in 80, 443, 9443) {
    $inUse = $false
    try {
        $c = [System.Net.NetworkInformation.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        $c.Start()
        $c.Stop()
    } catch { $inUse = $true }
    if ($inUse) { $busyPorts += $port }
}
$status = if ($busyPorts.Count -eq 0) { 'ok' }
          elseif (Test-RequiredFor @('server-windows','server-linux')) { 'warn' }
          else { 'n/a' }
Add-Check -Id 'ports' -Name 'Server ports free (80/443/9443)' -Status $status -RequiredFor @('server-windows','server-linux') -Detail $(if ($busyPorts.Count) { "busy: $($busyPorts -join ',')" } else { 'all free' }) -Fix 'Stop the process bound to the busy port (Caddy/nginx/IIS/other web server).'

# ---------------------------------------------------------------- 6. network (server)

$netOk = $false
try {
    $resp = Invoke-WebRequest -Uri 'https://api.github.com' -UseBasicParsing -TimeoutSec 8
    $netOk = $true
} catch { $netOk = $false }
$status = if ($netOk) { 'ok' } elseif (Test-RequiredFor @('server-windows','server-linux')) { 'warn' } else { 'n/a' }
Add-Check -Id 'internet' -Name 'Internet reachability (api.github.com)' -Status $status -RequiredFor @('server-windows','server-linux') -Detail $(if ($netOk) { 'reachable' } else { 'unreachable' }) -Fix 'Check firewall/proxy. GitHub remote build and WiX/sqlite downloads need internet.'

# ---------------------------------------------------------------- 7. report

$decision = $null
if ($target -eq 'server-windows') {
    $blockers = @($checks | Where-Object { $_.status -eq 'missing' })
    if ($blockers.Count -eq 0) { $decision = 'run deploy.ps1 (local build + sign + publish)' }
    else { $decision = 'missing blockers - install them (see fixes) then re-run' }
} elseif ($target -eq 'server-linux') {
    $blockers = @($checks | Where-Object { $_.status -eq 'missing' })
    if ($blockers.Count -eq 0) { $decision = 'run deploy.sh, then setup wizard with build_mode=github (repo + PAT)' }
    else { $decision = 'missing blockers - install them (see fixes) then re-run' }
} else {
    $blockers = @($checks | Where-Object { $_.status -eq 'missing' })
    if ($blockers.Count -eq 0) { $decision = 'agent-only test box: MSI + agent.json + ca.crt from the portal, no server needed' }
    else { $decision = 'missing blockers - install them (see fixes) then re-run' }
}

$overall = [pscustomobject]@{
    target       = $target
    blockers     = @($checks | Where-Object { $_.status -eq 'missing' }).Count
    warnings     = @($checks | Where-Object { $_.status -eq 'warn' }).Count
    ok           = @($checks | Where-Object { $_.status -eq 'ok' }).Count
    decision     = $decision
}

$report = [pscustomobject]@{
    target     = $target
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    os         = [pscustomobject]@{ platform = $osPlatform; elevated = $elevated; repo_path = $repoRoot }
    overall    = $overall
    checks     = $checks
}

$json = $report | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($ReportPath, $json, [System.Text.UTF8Encoding]::new($false))

if (-not $JsonOnly) {
    Write-Host ""
    Write-Host "IT-Toolkit Enterprise — prerequisite scan (target: $target)" -ForegroundColor Cyan
    Write-Host "Host: $osPlatform | elevated: $elevated | path: $repoRoot"
    Write-Host ("-" * 78)
    foreach ($c in $checks) {
        if ($c.status -eq 'ok')    { $color = 'Green' }
        elseif ($c.status -eq 'missing') { $color = 'Red' }
        elseif ($c.status -eq 'warn')    { $color = 'Yellow' }
        else                        { $color = 'Gray' }
        $tag = $c.status.PadRight(8)
        Write-Host ("[{0}] {1}" -f $tag, $c.name) -ForegroundColor $color -NoNewline
        if ($c.detail) { Write-Host "  ->  $($c.detail)" }
        else { Write-Host "" }
    }
    Write-Host ("-" * 78)
    Write-Host "Blockers: $($overall.blockers)   Warnings: $($overall.warnings)   OK: $($overall.ok)"
    Write-Host "Decision: $($overall.decision)" -ForegroundColor Cyan
    Write-Host "Report:   $ReportPath"
    Write-Host ""
}

if ($overall.blockers -gt 0) { exit 1 }
exit 0
