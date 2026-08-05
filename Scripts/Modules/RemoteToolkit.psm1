# RemoteToolkit.psm1 - Remote execution and orchestration for IT Toolkit
# Phase 2 module scaffold

<#
.SYNOPSIS
    Remote execution utilities for multi-machine diagnostics.

.DESCRIPTION
    Provides remote WinRM/SSH execution, parallel orchestration, and remote health checks.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Phase: 2
#>

# Get the script directory for path resolution
$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Test-RemoteConnection {
    <#
    .SYNOPSIS
        Verifies connectivity to a remote machine via WinRM.
    .PARAMETER ComputerName
        The remote host name or IP address.
    .PARAMETER Port
        Optional port to test; defaults to 5985.
    .PARAMETER UseSSL
        Use HTTPS for WinRM.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$false)][int]$Port = 5985,
        [Parameter(Mandatory=$false)][switch]$UseSSL
    )

    try {
        $uri = if ($UseSSL) { "https://${ComputerName}:$Port/wsman" } else { "http://${ComputerName}:$Port/wsman" }
        $session = New-PSSession -ConnectionUri $uri -ErrorAction Stop
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            return $true
        }
    } catch {
        return $false
    }
}

function Invoke-RemoteCommand {
    <#
    .SYNOPSIS
        Executes a command on a remote computer.
    .PARAMETER ComputerName
        Remote host name or IP.
    .PARAMETER ScriptBlock
        Script block to execute remotely.
    .PARAMETER Credential
        PSCredential object for authentication.
    .PARAMETER UseSSL
        Use SSL for WinRM.
    .PARAMETER ArgumentList
        Arguments to pass to the remote script block.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$false)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][switch]$UseSSL,
        [Parameter(Mandatory=$false)][object[]]$ArgumentList
    )

    $connectionUri = if ($UseSSL) { "https://${ComputerName}:5986/wsman" } else { $null }
    $params = @{ ComputerName = $ComputerName; ScriptBlock = $ScriptBlock; ErrorAction = 'Stop' }
    if ($Credential) { $params.Credential = $Credential }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }
    if ($connectionUri) { $params.ConnectionUri = $connectionUri }

    try {
        return Invoke-Command @params
    } catch {
        Write-Warning "Remote command failed on ${ComputerName}: $_"
        return $null
    }
}

function Invoke-ParallelRemoteExecution {
    <#
    .SYNOPSIS
        Executes a script block on multiple remote machines in parallel.
    .PARAMETER ComputerNames
        Array of remote hosts.
    .PARAMETER ScriptBlock
        Script block to execute.
    .PARAMETER Credential
        Optional PSCredential for authentication.
    .PARAMETER UseSSL
        Use SSL for WinRM.
    .PARAMETER MaxParallel
        Maximum parallel jobs.
    .PARAMETER ArgumentList
        Arguments to pass to the remote script block.
    #>
    param(
        [Parameter(Mandatory=$true)][string[]]$ComputerNames,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$false)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][switch]$UseSSL,
        [Parameter(Mandatory=$false)][int]$MaxParallel = 5,
        [Parameter(Mandatory=$false)][object[]]$ArgumentList
    )

    $jobs = @()
    foreach ($computer in $ComputerNames) {
        $jobs += Start-Job -ScriptBlock {
            param($computer, $scriptBlock, $credential, $useSSL, $argsList)
            $invokeParams = @{ ComputerName = $computer; ScriptBlock = $scriptBlock; ErrorAction = 'Stop' }
            if ($credential) { $invokeParams.Credential = $credential }
            if ($useSSL) { $invokeParams.ConnectionUri = "https://${computer}:5986/wsman" }
            if ($argsList) { $invokeParams.ArgumentList = $argsList }
            Invoke-Command @invokeParams
        } -ArgumentList $computer, $ScriptBlock, $Credential, $UseSSL.IsPresent, $ArgumentList

        while ($jobs.Count -ge $MaxParallel) {
            Wait-Job -Job $jobs -Any | Receive-Job -ErrorAction SilentlyContinue | Out-Null
            $jobs = $jobs | Where-Object { $_.State -eq 'Running' }
        }
    }

    if ($jobs.Count -gt 0) {
        Receive-Job -Job $jobs -Wait -AutoRemoveJob -ErrorAction SilentlyContinue | Out-Null
    }
}

function Get-RemoteComputerInfo {
    <#
    .SYNOPSIS
        Retrieves basic computer information from a remote machine.
    .PARAMETER ComputerName
        Remote host name or IP.
    .PARAMETER Credential
        PSCredential object for authentication.
    .PARAMETER UseSSL
        Use SSL for WinRM.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$false)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][switch]$UseSSL
    )

    $scriptBlock = {
        Get-CimInstance Win32_OperatingSystem | Select-Object CSName, Caption, Version, OSArchitecture, LastBootUpTime
    }

    return Invoke-RemoteCommand -ComputerName $ComputerName -ScriptBlock $scriptBlock -Credential $Credential -UseSSL:$UseSSL
}

function Invoke-RemoteNetworkDiagnostic {
    <#
    .SYNOPSIS
        Runs the network diagnostic script on a remote machine.
    .PARAMETER ComputerName
        Remote host name or IP.
    .PARAMETER ToolkitRoot
        Root path of the toolkit on the remote machine.
    .PARAMETER Credential
        PSCredential object for authentication.
    .PARAMETER UseSSL
        Use SSL for WinRM.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][string]$ToolkitRoot,
        [Parameter(Mandatory=$false)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][switch]$UseSSL
    )

    $scriptBlock = {
        param($remoteRoot)
        $networkScript = Join-Path $remoteRoot 'Scripts\Network-Diagnostic.ps1'
        if (Test-Path $networkScript) {
            & powershell -ExecutionPolicy Bypass -File $networkScript
        } else {
            Write-Error "Network-Diagnostic script not found at $networkScript"
        }
    }

    return Invoke-RemoteCommand -ComputerName $ComputerName -ScriptBlock $scriptBlock -Credential $Credential -UseSSL:$UseSSL -ArgumentList $ToolkitRoot
}

function Invoke-QuickCheckRemote {
    <#
    .SYNOPSIS
        Runs the QuickCheck script on a remote machine.
    .PARAMETER ComputerName
        Remote host name or IP.
    .PARAMETER ToolkitRoot
        Root path of the toolkit on the remote machine.
    .PARAMETER Credential
        PSCredential object for authentication.
    .PARAMETER UseSSL
        Use SSL for WinRM.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][string]$ToolkitRoot,
        [Parameter(Mandatory=$false)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][switch]$UseSSL
    )

    $scriptBlock = {
        param($remoteRoot)
        $quickCheckPath = Join-Path $remoteRoot 'Scripts\QuickCheck.ps1'
        if (Test-Path $quickCheckPath) {
            & powershell -ExecutionPolicy Bypass -File $quickCheckPath
        } else {
            Write-Error "QuickCheck script not found at $quickCheckPath"
        }
    }

    return Invoke-RemoteCommand -ComputerName $ComputerName -ScriptBlock $scriptBlock -Credential $Credential -UseSSL:$UseSSL -ArgumentList $ToolkitRoot
}

Export-ModuleMember -Function Test-RemoteConnection, Invoke-RemoteCommand, Invoke-ParallelRemoteExecution, Get-RemoteComputerInfo, Invoke-RemoteNetworkDiagnostic, Invoke-QuickCheckRemote
