# CredentialManager.psm1 - Secure credential storage for IT Toolkit
# Phase 2 module scaffold

<#
.SYNOPSIS
    Securely stores and retrieves toolkit credentials.

.DESCRIPTION
    Uses local Windows credential storage mechanisms to keep remote credentials safe.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Phase: 2
#>

function Store-ToolkitCredential {
    <#
    .SYNOPSIS
        Stores a PSCredential object securely.
    .PARAMETER TargetName
        Unique identifier for the credential.
    .PARAMETER Credential
        PSCredential object to store.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TargetName,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential
    )

    try {
        cmdkey.exe /generic:$TargetName /user:$($Credential.UserName) /pass:$($Credential.GetNetworkCredential().Password) | Out-Null
        return $true
    } catch {
        Write-Warning "Failed to store credential: $_"
        return $false
    }
}

function Get-ToolkitCredential {
    <#
    .SYNOPSIS
        Retrieves stored credential by target name.
    .PARAMETER TargetName
        Unique identifier for the credential.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TargetName
    )

    try {
        $output = cmdkey.exe /list:$TargetName 2>&1
        if ($output -match 'Target: $TargetName') {
            Write-Warning "Retrieving credentials from cmdkey is not supported in this environment. Use PSCredential directly.";
        }
        return $null
    } catch {
        Write-Warning "Failed to retrieve credential: $_"
        return $null
    }
}

function Test-CredentialValid {
    <#
    .SYNOPSIS
        Tests whether a PSCredential works for remote authentication.
    .PARAMETER ComputerName
        Remote host name or IP.
    .PARAMETER Credential
        PSCredential object to test.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential
    )

    try {
        $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            return $true
        }
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Store-ToolkitCredential, Get-ToolkitCredential, Test-CredentialValid
