<#
.SYNOPSIS
    Exports System, Application, and (optionally) Security error/warning
    events to a text file you can attach directly to a ticket or share
    with a vendor/escalation team.

.DESCRIPTION
    Sources, lookback window, and per-source event cap are configurable via
    Config/config.json -> eventLogSettings:
        exportSources   (array, default System, Application, Security)
        daysToExport    (number of days back, default 7)
        maxEventsPerSource (per-log cap, default 500)
    Falls back to the defaults above when the config key is absent.

.NOTES
    Elevated (admin) rights are required to read the Security log.
#>

# Load configuration via shared module when available
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "..\Config\config.json"
$config = $null
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Unable to parse config.json. Using defaults."
    }
}

# Settings: config wins, else documented defaults
$eventSettings = if ($config -and $config.eventLogSettings) { $config.eventLogSettings } else { $null }
$logSources   = if ($eventSettings -and $eventSettings.exportSources)       { @($eventSettings.exportSources) } else { @("System", "Application", "Security") }
$daysToExport = if ($eventSettings -and $eventSettings.daysToExport)         { [int]$eventSettings.daysToExport } else { 7 }
$maxEvents    = if ($eventSettings -and $eventSettings.maxEventsPerSource)   { [int]$eventSettings.maxEventsPerSource } else { 500 }

$logDir = Join-Path $PSScriptRoot "..\Logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$file = Join-Path $logDir "EventExport_$stamp.txt"

$hours = Read-Host "How many hours back should I check? (default $($daysToExport * 24))"
if ([string]::IsNullOrWhiteSpace($hours)) { $hours = $daysToExport * 24 }

# Load the shared sanitization module (falls back to an inline masker if missing)
$modulesPath = Join-Path (Split-Path -Parent $scriptDir) "Scripts\Modules"
$sanitizeModule = Join-Path $modulesPath "SanitizeEngine.psm1"
if (Test-Path $sanitizeModule) {
    Import-Module $sanitizeModule -ErrorAction Stop
} else {
    function ConvertTo-SanitizedText {
        param([string]$Text)
        if (-not $Text) { return $Text }
        $Text = $Text -replace '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[REDACTED-EMAIL]'
        $Text = $Text -replace '(?i)\b(\d{1,3}\.){3}\d{1,3}\b', '[REDACTED-IP]'
        $Text = $Text -replace '(?i)\b[A-Z]{2,}[\\/][A-Z0-9._-]+', '[REDACTED-ACCOUNT]'
        return $Text
    }
}

$knownHostnames = @()
if ($env:COMPUTERNAME) { $knownHostnames += $env:COMPUTERNAME }

"EVENT LOG EXPORT - Last $hours hours" | Out-File $file
"Generated: $(Get-Date) | Computer: $env:COMPUTERNAME" | Out-File $file -Append
"Sources: $($logSources -join ', ') | Max $maxEvents events per source | Sanitized: emails/IPs/accounts/hostnames masked" | Out-File $file -Append
"=================================================" | Out-File $file -Append

foreach ($log in $logSources) {
    "`n--- $log LOG (Errors + Warnings) ---" | Out-File $file -Append
    Get-WinEvent -FilterHashtable @{LogName=$log; Level=2,3; StartTime=(Get-Date).AddHours(-[int]$hours)} -MaxEvents $maxEvents -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        ForEach-Object {
            $_.Message = ConvertTo-SanitizedText -Text $_.Message -KnownHostnames $knownHostnames
            $_
        } |
        Format-List | Out-File $file -Append
}

Write-Host "`nExported to: $file" -ForegroundColor Green
Write-Host "Note: email addresses, IPs, domain accounts, and hostnames in event messages are masked ([REDACTED-*]). Review before external sharing." -ForegroundColor Yellow
notepad.exe $file
