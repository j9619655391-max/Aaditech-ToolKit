# ToolkitConfig.psm1 - Shared configuration loading and path resolution
# Part of IT Toolkit v2.0 Enhancement

<#
.SYNOPSIS
    Loads toolkit configuration and resolves tool-relative paths.

.DESCRIPTION
    Single source of truth for reading Config/config.json and resolving
    relative paths against the toolkit root. Replaces the duplicated
    bootstrap blocks that previously lived in each diagnostic script.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
#>

function Get-ToolkitConfig {
    <#
    .SYNOPSIS
        Loads Config/config.json as a PSCustomObject.
    .PARAMETER ScriptDir
        Directory of the calling script (used to locate the repo root).
    .OUTPUTS
        PSCustomObject or $null if config is missing/unparseable.
    #>
    param(
        [Parameter(Mandatory=$false)][string]$ScriptDir
    )

    if (-not $ScriptDir) {
        $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }

    $configPath = Join-Path $ScriptDir "..\Config\config.json"
    if (Test-Path $configPath) {
        try {
            return Get-Content $configPath -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Unable to parse config.json at $configPath. Using defaults."
        }
    }
    return $null
}

function Resolve-ToolPath {
    <#
    .SYNOPSIS
        Resolves a possibly-relative path against the toolkit root.
    .PARAMETER Path
        Absolute path, or relative path to join onto the toolkit root.
    .PARAMETER ScriptDir
        Directory of the calling script (used to locate the repo root).
    .OUTPUTS
        Resolved absolute path string.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$false)][string]$ScriptDir
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    if (-not $ScriptDir) {
        $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    $rootPath = Split-Path -Parent $ScriptDir
    return Join-Path $rootPath $Path
}

function Get-ToolkitDirectory {
    <#
    .SYNOPSIS
        Returns a configured toolkit directory (Logs, Scripts, Templates, ...).
    .PARAMETER Config
        Config object from Get-ToolkitConfig.
    .PARAMETER Key
        Path key to look up under config.paths.
    .PARAMETER Default
        Default relative path used when config is absent.
    .PARAMETER ScriptDir
        Directory of the calling script.
    .OUTPUTS
        Absolute directory path.
    #>
    param(
        [Parameter(Mandatory=$false)][PSCustomObject]$Config,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Default,
        [Parameter(Mandatory=$false)][string]$ScriptDir
    )

    if ($Config -and $Config.paths -and $Config.paths.($Key)) {
        return Resolve-ToolPath -Path $Config.paths.($Key) -ScriptDir $ScriptDir
    }
    return Resolve-ToolPath -Path $Default -ScriptDir $ScriptDir
}

Export-ModuleMember -Function Get-ToolkitConfig, Resolve-ToolPath, Get-ToolkitDirectory
