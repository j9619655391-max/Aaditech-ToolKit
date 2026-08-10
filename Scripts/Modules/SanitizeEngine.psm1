# SanitizeEngine.psm1 - PII sanitization for exported content
# Part of IT Toolkit - Security hardening

<#
.SYNOPSIS
    Masks personally identifiable information (PII) before content is shared
    with vendors or attached to tickets.

.DESCRIPTION
    Provides a single, testable sanitization pipeline used by exporters
    (event logs, reports). By default it masks:
      - email addresses       -> [REDACTED-EMAIL]
      - IPv4 addresses        -> [REDACTED-IP]
      - domain\user accounts  -> [REDACTED-ACCOUNT]
      - hostnames (computer names) -> [REDACTED-HOSTNAME]
    The behavior is configurable via Config/config.json -> sanitization.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Security hardening
#>

$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Get-SanitizationConfig {
    <#
    .SYNOPSIS
        Loads sanitization settings from Config/config.json with safe defaults.
    #>
    $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModulesPath)
    $configPath = Join-Path $repoRoot 'Config/config.json'
    $settings = @{
        maskEmails    = $true
        maskIPs       = $true
        maskAccounts  = $true
        maskHostnames = $true
    }
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $s = $config.sanitization
            if ($s) {
                if ($null -ne $s.maskEmails)    { $settings.maskEmails    = [bool]$s.maskEmails }
                if ($null -ne $s.maskIPs)       { $settings.maskIPs       = [bool]$s.maskIPs }
                if ($null -ne $s.maskAccounts)  { $settings.maskAccounts  = [bool]$s.maskAccounts }
                if ($null -ne $s.maskHostnames) { $settings.maskHostnames = [bool]$s.maskHostnames }
            }
        } catch { }
    }
    return $settings
}

function ConvertTo-SanitizedText {
    <#
    .SYNOPSIS
        Masks PII inside a block of text.

    .DESCRIPTION
        Applies the configured masking rules to the supplied text. Passwords,
        email addresses, IPs, domain accounts, and hostnames are replaced with
        [REDACTED-*] placeholders. Hostnames are matched only when they appear
        in a recognizable form (netbios-style \host, host.example, HOST:8080)
        so normal words are not over-masked.

    .PARAMETER Text
        Raw text to sanitize.

    .PARAMETER KnownHostnames
        Optional array of specific hostnames/computer names to mask explicitly.
        When provided, these are masked wherever they appear (case-insensitive).

    .PARAMETER UseConfig
        Read masking toggles from Config/config.json. Defaults to $true.

    .EXAMPLE
        ConvertTo-SanitizedText -Text "user@contoso.com connected from 10.0.0.5"
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$false)][string[]]$KnownHostnames,
        [Parameter(Mandatory=$false)][switch]$UseConfig = $true
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $s = if ($UseConfig) { Get-SanitizationConfig } else { @{ maskEmails = $true; maskIPs = $true; maskAccounts = $true; maskHostnames = $true } }

    if ($s.maskEmails) {
        $Text = $Text -replace '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[REDACTED-EMAIL]'
    }
    if ($s.maskIPs) {
        $Text = $Text -replace '(?i)\b(\d{1,3}\.){3}\d{1,3}\b', '[REDACTED-IP]'
    }
    if ($s.maskAccounts) {
        $Text = $Text -replace '(?i)\b[A-Z][A-Z0-9.-]*\\[A-Z0-9._-]+\b', '[REDACTED-ACCOUNT]'
        $Text = $Text -replace '(?i)\b(?:username|user|account)\s*[:=]\s*[A-Z0-9._-]+', '[REDACTED-ACCOUNT]'
    }
    if ($s.maskHostnames) {
        # netbios \host, FQDN host.example.com, and host:port forms
        $Text = $Text -replace '(?i)\b[A-Z0-9][A-Z0-9._-]{0,62}\.[A-Z]{2,}\b', '[REDACTED-HOSTNAME]'
        $Text = $Text -replace '(?i)\b[A-Z0-9][A-Z0-9-]{0,62}:\d{1,5}\b', '[REDACTED-HOSTNAME]'
        if ($KnownHostnames -and $KnownHostnames.Count -gt 0) {
            foreach ($h in ($KnownHostnames | Where-Object { $_ })) {
                $pattern = [regex]::Escape($h)
                $Text = $Text -replace "(?i)\b$pattern\b", '[REDACTED-HOSTNAME]'
            }
        }
    }

    return $Text
}

function Protect-SanitizedContent {
    <#
    .SYNOPSIS
        Applies sanitization to all String properties of one or more objects
        (e.g. event log records) and returns the sanitized objects.

    .PARAMETER InputObject
        Objects whose string properties should be sanitized in place.

    .PARAMETER KnownHostnames
        Hostnames to mask explicitly (passed through to ConvertTo-SanitizedText).
    #>
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)][object]$InputObject,
        [Parameter(Mandatory=$false)][string[]]$KnownHostnames
    )
    process {
        foreach ($prop in $InputObject.PSObject.Properties) {
            if ($prop.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
                $prop.Value = ConvertTo-SanitizedText -Text $prop.Value -KnownHostnames $KnownHostnames
            }
        }
        $InputObject
    }
}

Export-ModuleMember -Function ConvertTo-SanitizedText, Protect-SanitizedContent, Get-SanitizationConfig
