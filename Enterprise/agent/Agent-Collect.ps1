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

# ---------------------------------------------------------------- mTLS client cert (hardening)
# When the config carries an enroll_url, the agent fetches a client-auth cert
# signed by the server's local CA once (bearer token auth) and then presents it
# to the agent mTLS endpoint (port 9443). Without enroll_url the agent keeps
# using plain bearer-token auth, so this is fully backward compatible.

function Get-ClientCertPath {
    param($Config)
    if (-not $Config.enroll_url) { return $null }
    $dir = Split-Path $ConfigPath -Parent
    return Join-Path $dir 'client.pfx'
}

function Ensure-ClientCert {
    param($Config)
    $pfx = Get-ClientCertPath -Config $Config
    if (-not $pfx) { return $null }
    if (Test-Path $pfx) { return $pfx }

    Write-AgentLog "Enrolling for mTLS client cert from $($Config.enroll_url)"
    try {
        $resp = Invoke-RestMethod -Uri $Config.enroll_url -Method Get `
            -Headers @{ Authorization = "Bearer $($Config.token)" }
        if (-not $resp.pfx) { throw "enroll returned no pfx" }
        [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($resp.pfx))
        Write-AgentLog "Client cert saved to $pfx"
        return $pfx
    }
    catch {
        Write-AgentLog "mTLS enroll failed: $($_.Exception.Message) — falling back to bearer auth"
        return $null
    }
}

function Get-RestCertificate {
    param($Config)
    $pfx = Get-ClientCertPath -Config $Config
    if (-not $pfx -or -not (Test-Path $pfx)) { return $null }
    try { return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx) }
    catch { Write-AgentLog "Failed to load client cert: $($_.Exception.Message)"; return $null }
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

function ConvertFrom-CollectorOutput {
    # Collectors (Enterprise/agent/collectors/*) emit one JSON object so the
    # server can build fleet panels. Anything that doesn't parse as JSON is
    # treated as plain text and wrapped in { text = ... } as before.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return ($Raw | ConvertFrom-Json) }
    catch { return $Raw }
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
            $structured = ConvertFrom-CollectorOutput -Raw $output
            $payload = ConvertTo-JsonPayload -Result $structured
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
    $cert = Get-RestCertificate -Config $Config
    if ($cert) {
        Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body -Certificate $cert
    }
    else {
        Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body
    }
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
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            $resp = Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body -Certificate $cert
        }
        else {
            $resp = Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body
        }
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

# ------------------------------------------------------------------ commands (P5)

function Get-CommandsApiRoot {
    # same origin as the ingest endpoint, minus the /ingest suffix
    return ($Config.endpoint -replace '/ingest\s*$', '')
}

function Get-PendingCommands {
    param($Config)
    $hn = [uri]::EscapeDataString((Get-AgentHostname))
    $uri = "$(Get-CommandsApiRoot)/api/commands/poll?hostname=$hn"
    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $($Config.token)" } -Certificate $cert
        }
        else {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $($Config.token)" }
        }
        return @($resp)
    }
    catch {
        Write-AgentLog "Command poll failed: $($_.Exception.Message)"
        return @()
    }
}

function Send-WakeOnLan {
    param([string]$Mac, [string]$TargetIp)
    $bytes = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    $parts = $Mac -split '[:-]'
    if ($parts.Count -ne 6) { throw "Invalid MAC address: $Mac" }
    $macBytes = @($parts | ForEach-Object { [Convert]::ToByte($_, 16) })
    for ($i = 0; $i -lt 16; $i++) { $bytes += $macBytes }
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        if ($TargetIp) { $client.Send($bytes, $bytes.Length, $TargetIp, 9) | Out-Null }
        else { $client.Send($bytes, $bytes.Length, '255.255.255.255', 9) | Out-Null }
    }
    finally { $client.Close() }
}

function Invoke-RemoteCommand {
    param($Config, $Cmd)
    $kind = $Cmd.kind
    $payload = $Cmd.payload
    switch ($kind) {
        'reboot' {
            $delay = [int]$payload.delay_seconds
            if ($delay -gt 0) {
                & shutdown.exe /r /t $delay /f 2>&1 | Out-Null
            }
            else {
                Restart-Computer -Force -ErrorAction Stop
            }
            return @{ status = 'completed'; output = "Reboot issued (delay $delay s)"; exit_code = 0 }
        }
        'wake' {
            try {
                Send-WakeOnLan -Mac $payload.mac -TargetIp $payload.ip
                return @{ status = 'completed'; output = "Wake-on-LAN sent to $($payload.mac)"; exit_code = 0 }
            }
            catch {
                return @{ status = 'failed'; output = $_.Exception.Message; exit_code = 1 }
            }
        }
        'run-script' {
            $script = $payload.script
            if (-not $script) { return @{ status = 'failed'; output = 'No script specified'; exit_code = 1 } }
            $path = Join-Path $script:RepoRoot $script
            if (-not (Test-Path $path)) { return @{ status = 'failed'; output = "Script not found: $script"; exit_code = 1 } }
            try {
                $out = (& $path 2>&1 | Out-String)
                return @{ status = 'completed'; output = $out; exit_code = $LASTEXITCODE }
            }
            catch {
                return @{ status = 'failed'; output = $_.Exception.Message; exit_code = 1 }
            }
        }
        default { return @{ status = 'failed'; output = "Unknown command kind: $kind"; exit_code = 1 } }
    }
}

function Send-CommandResult {
    param($Config, $CmdId, $Result)
    $uri = "$(Get-CommandsApiRoot)/api/commands/$CmdId/result"
    $body = @{
        hostname  = (Get-AgentHostname)
        status    = $Result.status
        output    = $Result.output
        exit_code = $Result.exit_code
    } | ConvertTo-Json -Compress
    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body -Certificate $cert | Out-Null
        }
        else {
            Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $($Config.token)" } -ContentType 'application/json' -Body $body | Out-Null
        }
        Write-AgentLog "Posted result for command $CmdId : $($Result.status)"
    }
    catch {
        Write-AgentLog "Result post failed for command $CmdId : $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ main

Import-ToolkitModules
Initialize-Queue
$Config = Read-AgentConfig

Write-AgentLog "Agent cycle start (endpoint: $($Config.endpoint))"

# mTLS: fetch the client cert once before the first endpoint call.
$null = Ensure-ClientCert -Config $Config

do {
    if (-not $FlushOnly) {
        $ran = Invoke-AgentCollection -Config $Config
        Write-AgentLog "Collected: $($ran -join ', ')"
    }

    if (-not $CollectOnly) {
        $sent = Send-AgentBatch -Config $Config
        Write-AgentLog "Sent: $sent events"
    }

    if (-not $FlushOnly -and -not $CollectOnly) {
        $cmds = Get-PendingCommands -Config $Config
        foreach ($cmd in $cmds) {
            Write-AgentLog "Executing command $($cmd.id) kind=$($cmd.kind)"
            $result = Invoke-RemoteCommand -Config $Config -Cmd $cmd
            Send-CommandResult -Config $Config -CmdId $cmd.id -Result $result
        }
        if (@($cmds).Count -gt 0) { Write-AgentLog "Executed $($cmds.Count) command(s)" }
    }

    Write-AgentLog "Agent cycle complete"

    if ($LoopMinutes -gt 0) {
        Start-Sleep -Seconds ($LoopMinutes * 60)
    }
} while ($LoopMinutes -gt 0)
