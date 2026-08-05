# CredentialManager.psm1 - Secure credential storage for IT Toolkit
# Phase 2 module

<#
.SYNOPSIS
    Securely stores and retrieves toolkit credentials.

.DESCRIPTION
    Stores credentials WITHOUT exposing plaintext passwords on any command
    line. Storage priority:

      1. Microsoft.PowerShell.SecretManagement vault (preferred, secure)
      2. DPAPI-encrypted Export-Clixml file (Windows, encrypted to current user)
      3. AES-encrypted SecureString file (cross-platform, keyed per user)

    Never uses cmdkey with a plaintext /pass argument.

.NOTES
    Author: IT Toolkit Team
    Version: 2.0
    Phase: 2
#>

$script:VaultName = 'ITToolkitVault'
if ($env:LOCALAPPDATA) {
    $script:CredBase = $env:LOCALAPPDATA
} else {
    $script:CredBase = Join-Path $HOME '.it-toolkit'
}
$script:CredDir = Join-Path $script:CredBase 'credentials'
$script:CredFile = Join-Path $script:CredDir 'toolkit-credentials.xml'
$script:KeyFile = Join-Path $script:CredDir 'toolkit.key'

function Get-SecretManagementAvailable {
    return [bool](Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue)
}

function Get-IsWindows {
    return ($env:OS -eq 'Windows_NT' -or [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows))
}

function Initialize-CredentialStore {
    if (-not (Test-Path $script:CredDir)) {
        New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null
    }
    # Restrict directory permissions to the current user where supported.
    try {
        if (Get-IsWindows) {
            $acl = Get-Acl $script:CredDir
            $acl.SetAccessRuleProtection($true, $false)
            $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($current, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -Path $script:CredDir -AclObject $acl -ErrorAction SilentlyContinue
        }
    } catch {
        # best-effort; do not fail the whole operation
    }
}

function Get-StoreKey {
    <#
    .SYNOPSIS
        Returns (or creates) the per-user AES key used for the cross-platform
        file fallback. The key is itself protected by the OS where possible.
    #>
    if (-not (Test-Path $script:KeyFile)) {
        $key = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
        $rng.GetBytes($key)
        [System.IO.File]::WriteAllBytes($script:KeyFile, $key)
        # best-effort restrictive ACL on the key file
        if (Get-IsWindows) {
            try {
                $acl = Get-Acl $script:KeyFile
                $acl.SetAccessRuleProtection($true, $false)
                $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($current, 'FullControl', 'None', 'None', 'Allow')
                $acl.AddAccessRule($rule)
                Set-Acl -Path $script:KeyFile -AclObject $acl -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    return [System.IO.File]::ReadAllBytes($script:KeyFile)
}

function Store-ToolkitCredential {
    <#
    .SYNOPSIS
        Stores a PSCredential object securely without exposing its password.

    .DESCRIPTION
        Uses Microsoft.PowerShell.SecretManagement when available. Otherwise
        falls back to an OS-encrypted file. Never passes the password as a
        command-line argument.

    .PARAMETER TargetName
        Unique identifier for the credential.

    .PARAMETER Credential
        PSCredential object to store.

    .PARAMETER Force
        Overwrite an existing entry with the same TargetName.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TargetName,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][switch]$Force
    )

    try {
        if (Get-SecretManagementAvailable) {
            if (-not (Get-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue)) {
                Register-SecretVault -Name $script:VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault -ErrorAction Stop
            }
            if ($Force) {
                Set-Secret -Name $TargetName -Secret $Credential.GetNetworkCredential().Password -Vault $script:VaultName -ErrorAction Stop
            } else {
                if (Get-Secret -Name $TargetName -Vault $script:VaultName -ErrorAction SilentlyContinue) {
                    Write-Warning "Credential '$TargetName' already exists. Use -Force to overwrite."
                    return $false
                }
                Set-Secret -Name $TargetName -Secret $Credential.GetNetworkCredential().Password -Vault $script:VaultName -ErrorAction Stop
            }
            return $true
        }

        # Fallback: secure file storage (no plaintext on any command line)
        Initialize-CredentialStore
        if (-not (Test-Path $script:CredFile)) {
            New-Object psobject | Export-Clixml -Path $script:CredFile
        }
        $store = @(Import-Clixml $script:CredFile)

        $existing = $store | Where-Object { $_.TargetName -eq $TargetName }
        if ($existing -and -not $Force) {
            Write-Warning "Credential '$TargetName' already exists. Use -Force to overwrite."
            return $false
        }

        $secure = $Credential.Password
        if (Get-IsWindows) {
            # DPAPI-encrypted secure string (bound to current user) via ConvertTo-SecureString round-trip
            $enc = ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop
        } else {
            $enc = ConvertFrom-SecureString -SecureString $secure -Key (Get-StoreKey) -ErrorAction Stop
        }

        $store = @($store | Where-Object { $_.TargetName -ne $TargetName })
        $entry = [PSCustomObject]@{
            TargetName = $TargetName
            UserName   = $Credential.UserName
            Encrypted  = $enc
        }
        $store += $entry
        $store | Export-Clixml -Path $script:CredFile -Force
        return $true
    } catch {
        Write-Warning "Failed to store credential: $_"
        return $false
    }
}

function Get-ToolkitCredential {
    <#
    .SYNOPSIS
        Retrieves a stored credential as a PSCredential.

    .PARAMETER TargetName
        Unique identifier for the credential.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TargetName
    )

    try {
        if (Get-SecretManagementAvailable) {
            $secret = Get-Secret -Name $TargetName -Vault $script:VaultName -ErrorAction SilentlyContinue
            if ($null -eq $secret) { return $null }
            $username = $TargetName.Split('\')[-1]
            $secure = ConvertTo-SecureString $secret -AsPlainText -Force
            return [System.Management.Automation.PSCredential]::new($username, $secure)
        }

        if (-not (Test-Path $script:CredFile)) { return $null }
        $store = @(Import-Clixml $script:CredFile)
        $entry = $store | Where-Object { $_.TargetName -eq $TargetName }
        if (-not $entry) { return $null }

        if (Get-IsWindows) {
            $secure = ConvertTo-SecureString -String $entry.Encrypted -ErrorAction Stop
        } else {
            $secure = ConvertTo-SecureString -String $entry.Encrypted -Key (Get-StoreKey) -ErrorAction Stop
        }
        return [System.Management.Automation.PSCredential]::new($entry.UserName, $secure)
    } catch {
        Write-Warning "Failed to retrieve credential: $_"
        return $null
    }
}

function Remove-ToolkitCredential {
    <#
    .SYNOPSIS
        Removes a stored credential.

    .PARAMETER TargetName
        Unique identifier for the credential to remove.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TargetName
    )

    try {
        if (Get-SecretManagementAvailable) {
            Remove-Secret -Name $TargetName -Vault $script:VaultName -ErrorAction SilentlyContinue
            return $true
        }
        if (-not (Test-Path $script:CredFile)) { return $false }
        $store = @(Import-Clixml $script:CredFile) | Where-Object { $_.TargetName -ne $TargetName }
        $store | Export-Clixml -Path $script:CredFile -Force
        return $true
    } catch {
        Write-Warning "Failed to remove credential: $_"
        return $false
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
    .PARAMETER TimeoutSeconds
        Seconds to wait for the WinRM connection test.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$false)][int]$TimeoutSeconds = 10
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

Export-ModuleMember -Function Store-ToolkitCredential, Get-ToolkitCredential, Remove-ToolkitCredential, Test-CredentialValid
