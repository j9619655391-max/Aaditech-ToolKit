<#
.SYNOPSIS
    Generates .rdp shortcut files for machines you connect to often, so you can
    double-click instead of typing the hostname/IP into Remote Desktop every time.
.USAGE
    Edit the $machines list below with your own hostnames/IPs and friendly names,
    then run this script once. It creates one .rdp file per machine in this folder.
#>

# Load configuration
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "..\Config\config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($config.machines) {
        $machines = $config.machines
    } else {
        $machines = @(
            @{ Name = "Example-Server01"; Host = "192.168.1.10" }
            @{ Name = "Example-Workstation02"; Host = "192.168.1.55" }
            # Add more as needed:
            # @{ Name = "Friendly-Name"; Host = "hostname-or-ip" }
        )
    }
} else {
    $machines = @(
        @{ Name = "Example-Server01"; Host = "192.168.1.10" }
        @{ Name = "Example-Workstation02"; Host = "192.168.1.55" }
        # Add more as needed:
        # @{ Name = "Friendly-Name"; Host = "hostname-or-ip" }
    )
}

foreach ($m in $machines) {
    $content = @"
full address:s:$($m.Host)
prompt for credentials:i:1
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
authentication level:i:2
"@
    $path = Join-Path $PSScriptRoot "$($m.Name).rdp"
    $content | Out-File -FilePath $path -Encoding ASCII
    Write-Host "Created: $path"
}

Write-Host "`nDone. Double-click any .rdp file above to connect." -ForegroundColor Green
