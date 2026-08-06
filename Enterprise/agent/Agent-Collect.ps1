# Agent-Collect.ps1 - IT-Toolkit Enterprise agent worker
# Part of IT-Toolkit Enterprise (Phase 3). Wraps EXISTING toolkit scripts
# WITHOUT modifying them: runs them, sanitizes output, queues locally, and
# ships to the enterprise server. This is the file packaged as
# IT-Toolkit-Agent.exe by ps2exe and installed by the MSI.

[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\ITToolkit-Agent\agent.json",
    [string]$QueueDb = "$env:ProgramData\ITToolkit-Agent\queue.sqlite3",
    [int]$LoopMinutes = 0,
    [switch]$CollectOnly,
    [switch]$FlushOnly
)

$ErrorActionPreference = 'Stop'

function Resolve-ToolkitRoot {
    # Installed layout:  <InstallRoot>\Scripts\Modules, <InstallRoot>\Config
    # Repo layout:       <repo>\Scripts\Modules,       <repo>\Config
    $candidates = @(
        (Join-Path $PSScriptRoot 'Scripts\Modules'),
        (Join-Path $PSScriptRoot '..\..\Scripts\Modules')
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'SanitizeEngine.psm1')) {
            return Split-Path (Split-Path $c -Parent) -Parent   # <root>\Scripts\Modules -> <root>
        }
    }
    return $PSScriptRoot
}
$script:RepoRoot    = Resolve-ToolkitRoot
$script:ModulesPath = Join-Path $script:RepoRoot 'Scripts\Modules'

function Write-AgentLog {
    param([string]$Message)
    $dir = Split-Path $ConfigPath -Parent
    $logDir = Join-Path $dir 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path (Join-Path $logDir 'agent.log') -Value $line -ErrorAction SilentlyContinue
    Write-Verbose $line
}

function Read-AgentConfig {
    if (-not (Test-Path $ConfigPath)) {
        throw "Agent config not found at $ConfigPath. Reinstall the MSI or run build-agent.ps1."
    }
    try { return (Get-Content $ConfigPath -Raw | ConvertFrom-Json) }
    catch { throw "Invalid agent.json: $($_.Exception.Message)" }
}

function Import-ToolkitModules {
    # Reuse existing modules unchanged.
    Import-Module (Join-Path $script:ModulesPath 'SanitizeEngine.psm1') -Force
    Import-Module (Join-Path $script:ModulesPath 'ToolkitData.psm1') -Force
}

function Initialize-Queue {
    if (-not (Test-Path (Split-Path $QueueDb -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path $QueueDb -Parent) -Force | Out-Null
    }
    $schema = @"
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  sanitized INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  status TEXT NOT NULL DEFAULT 'pending'
);
"@
    Invoke-SQLite -Query $schema -DatabasePath $QueueDb | Out-Null
}

function ConvertTo-JsonPayload {
    param([object]$Result)
    if ($null -eq $Result) { return (@{} | ConvertTo-Json -Compress) }
    if ($Result -is [string]) {
        $sanitized = ConvertTo-SanitizedText -Text $Result
        return (@{ text = $sanitized } | ConvertTo-Json -Compress)
    }
    $sanitized = $Result | Protect-SanitizedContent
    return ($sanitized | ConvertTo-Json -Compress -Depth 10)
}

function Invoke-AgentCollection {
    param($Config)
    $results = @()
    $endpoint = $Config.endpoint
    $token = $Config.token

    foreach ($feature in $Config.features) {
        if (-not $feature.enabled) { continue }
        $scriptPath = $feature.script
        if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
            $scriptPath = Join-Path $script:RepoRoot $feature.script
        }
        if (-not (Test-Path $scriptPath)) {
            Write-AgentLog "Skipping $($feature.name): script missing $scriptPath"
            continue
        }
        try {
            Write-AgentLog "Running $($feature.name) ($scriptPath)"
            $output = & $scriptPath 2>&1 | Out-String
            $payload = ConvertTo-JsonPayload -Result $output
            Invoke-SQLite -Query "INSERT INTO outbox (kind, payload, sanitized) VALUES ('$($feature.name)', '$($payload.Replace("'","''"))', 1);" -DatabasePath $QueueDb | Out-Null
            $results += $feature.name
        }
        catch {
            Write-AgentLog "Collection failed for $($feature.name): $($_.Exception.Message)"
            # Still queue the error so the server sees agent health issues.
            $err = @{ feature = $feature.name; error = $_.Exception.Message } | ConvertTo-Json -Compress
            Invoke-SQLite -Query "INSERT INTO outbox (kind, payload, sanitized) VALUES ('agent-error', '$($err.Replace("'","''"))', 1);" -DatabasePath $QueueDb | Out-Null
        }
    }
    return $results
}

function Get-AgentHostname {
    foreach ($candidate in @($env:COMPUTERNAME, $env:HOSTNAME)) {
        if ($candidate) { return $candidate }
    }
    $hn = (& hostname 2>$null)
    if ($hn) { return $hn.Trim() }
    return 'unknown-host'
}

function Get-AgentIP {
    <#
    .SYNOPSIS
        Best-effort IPv4 address of this machine ('' on any failure so a flush
        can never be killed by IP discovery).
    #>
    try {
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } |
                Select-Object -First 1 -ExpandProperty IPAddress
            if ($ip) { return $ip }
        }
        # fallback: parse ifconfig/ipconfig output
        $raw = (& ifconfig 2>$null) -join "`n"
        if ($raw) {
            $m = [regex]::Match($raw, '(?m)inet (addr:)?(\d{1,3}(\.\d{1,3}){3})')
            if ($m.Success) {
                $cand = $m.Groups[2].Value
                if ($cand -notlike '127.*') { return $cand }
            }
        }
    } catch { }
    return ''
}

function Send-AgentHeartbeat {
    param($Config)
    $body = @{
        hostname      = (Get-AgentHostname)
        os            = [System.Environment]::OSVersion.VersionString
        agent_version = $Config.agent_version
        ip            = (Get-AgentIP)
        events        = @()
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body
}

function Send-AgentBatch {
    param($Config)
    $pending = Invoke-SQLite -Query "SELECT id, kind, payload, sanitized, created_at FROM outbox WHERE status='pending' ORDER BY id ASC LIMIT 50;" -DatabasePath $QueueDb -AsJson
    if ([string]::IsNullOrWhiteSpace($pending)) { return 0 }

    $events = foreach ($row in ($pending | ConvertFrom-Json)) {
        @{
            kind         = $row.kind
            payload      = ($row.payload | ConvertFrom-Json)
            sanitized    = [bool]$row.sanitized
            client_msg_id = "$($env:COMPUTERNAME):$($row.id)"
            captured_at  = $row.created_at
        }
    }
    $body = @{
        hostname      = (Get-AgentHostname)
        os            = [System.Environment]::OSVersion.VersionString
        agent_version = $Config.agent_version
        ip            = (Get-AgentIP)
        events        = @($events)
    } | ConvertTo-Json -Compress -Depth 12

    try {
        $resp = Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body
        $ids = (@($pending | ConvertFrom-Json) | ForEach-Object { $_.id }) -join ','
        Invoke-SQLite -Query "UPDATE outbox SET status='delivered' WHERE id IN ($ids);" -DatabasePath $QueueDb | Out-Null
        Write-AgentLog "Flushed batch: $($resp.accepted) events accepted"
        return $resp.accepted
    }
    catch {
        Write-AgentLog "Flush failed (will retry next cycle): $($_.Exception.Message)"
        return 0
    }
}

# ------------------------------------------------------------------ main

Import-ToolkitModules
Initialize-Queue
$Config = Read-AgentConfig

Write-AgentLog "Agent cycle start (endpoint: $($Config.endpoint))"

do {
    if (-not $FlushOnly) {
        $ran = Invoke-AgentCollection -Config $Config
        Write-AgentLog "Collected: $($ran -join ', ')"
    }

    if (-not $CollectOnly) {
        $sent = Send-AgentBatch -Config $Config
        Write-AgentLog "Sent: $sent events"
    }

    Write-AgentLog "Agent cycle complete"

    if ($LoopMinutes -gt 0) {
        Start-Sleep -Seconds ($LoopMinutes * 60)
    }
} while ($LoopMinutes -gt 0)
